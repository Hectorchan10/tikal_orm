import 'package:postgres/postgres.dart' as pg;

// Database
import '../query_result.dart';
import '../query_executor.dart';
import '../transaction_isolation.dart';

// Config
import '../../config/postgres_config.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Database
import '../internal/database_connection.dart';
import '../internal/session_query_executor.dart';

/// Lazy PostgreSQL connection pool, validated by open and released by close.
final class PostgresConnection implements DatabaseConnection {
  /// Creates a handle for [config]. No connection is opened yet.
  PostgresConnection(this.config);

  @override
  SqlDialect get dialect => SqlDialect.postgres;

  /// The settings this database was created with.
  final PostgresConfig config;

  pg.Pool<Object?>? _pool;
  SessionQueryExecutor? _executor;
  Future<void>? _opening;
  bool _isClosed = false;

  /// Whether the pool exists and has not been closed.
  @override
  bool get isOpen => _pool != null && !_isClosed;

  /// Whether the database has not been opened yet, or has been closed.
  bool get isClosed => !isOpen;

  /// Opens the pool and validates the connection with a round trip.
  ///
  /// Safe to call repeatedly: concurrent and later calls share the first
  /// attempt. Throws [TikalConnectionException] when the database cannot be
  /// reached, and [TikalDatabaseClosedException] once [close] was called.
  @override
  Future<void> open() {
    if (_isClosed) {
      throw const TikalDatabaseClosedException(
        'This PostgresConnection has been closed; create a new instance instead of reusing it.',
      );
    }
    if (isOpen) return Future<void>.value();
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    final pool = pg.Pool<Object?>.withEndpoints(<pg.Endpoint>[
      _endpoint(config),
    ], settings: _poolSettings(config));
    final executor = SessionQueryExecutor(pool);
    try {
      await executor.query('SELECT 1', timeout: config.queryTimeout);
    } catch (error) {
      try {
        await pool.close(force: true);
      } catch (_) {
        // The pool never became usable; there is nothing else to release.
      }
      throw TikalConnectionException(
        'Could not connect to PostgreSQL at ${config.describe()}. '
        'Check that the server is running and that the credentials are correct. '
        'Cause: $error',
        cause: error,
      );
    }
    _pool = pool;
    _executor = executor;
  }

  /// Returns `true` when the database answers `SELECT 1`.
  ///
  /// Useful for health checks such as Dart Frog's `/_health` route. Never
  /// throws: connection problems are reported as `false`.
  @override
  Future<bool> ping() async {
    if (!isOpen) return false;
    try {
      await _executor!.query('SELECT 1', timeout: const Duration(seconds: 5));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Closes the pool and releases every connection.
  ///
  /// The instance cannot be reopened afterwards: create a new `PostgresConnection`.
  /// When [force] is `true`, in-flight statements are cancelled instead of
  /// being awaited. An in-flight open is awaited before releasing its pool;
  /// failed initialization is already cleaned up and does not prevent close.
  @override
  Future<void> close({bool force = false}) async {
    _isClosed = true;
    try {
      await _opening;
    } on TikalConnectionException {
      // Failed initialization already released the pool; closing remains safe.
    }
    final pool = _pool;
    _pool = null;
    _executor = null;
    await pool?.close(force: force);
  }

  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const <Object?>[],
    Duration? timeout,
  }) => _run(
    (executor, resolved) =>
        executor.query(sql, parameters: parameters, timeout: resolved),
    timeout: timeout,
  );

  @override
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
    Duration? timeout,
  }) => _run(
    (executor, resolved) =>
        executor.queryNamed(sql, parameters: parameters, timeout: resolved),
    timeout: timeout,
  );

  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const <Object?>[],
    Duration? timeout,
  }) => _run(
    (executor, resolved) =>
        executor.execute(sql, parameters: parameters, timeout: resolved),
    timeout: timeout,
  );

  @override
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
    Duration? timeout,
  }) => _run(
    (executor, resolved) =>
        executor.executeNamed(sql, parameters: parameters, timeout: resolved),
    timeout: timeout,
  );

  /// Runs [action] inside a transaction.
  ///
  /// The transaction is committed when [action] completes and rolled back when
  /// it throws; the original error is rethrown either way.
  ///
  /// ```dart
  /// await db.transaction((tx) async {
  ///   await tx.execute('UPDATE accounts SET balance = balance - \$1 WHERE id = \$2', parameters: [100, from]);
  ///   await tx.execute('UPDATE accounts SET balance = balance + \$1 WHERE id = \$2', parameters: [100, to]);
  /// });
  /// ```
  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor tx) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) async {
    await _executorOrOpen();
    try {
      return await _pool!.runTx<T>(
        (session) => action(SessionQueryExecutor.forTransaction(session)),
        settings: pg.TransactionSettings(
          isolationLevel: switch (isolation) {
            TransactionIsolation.readCommitted =>
              pg.IsolationLevel.readCommitted,
            TransactionIsolation.repeatableRead =>
              pg.IsolationLevel.repeatableRead,
            TransactionIsolation.serializable => pg.IsolationLevel.serializable,
            null => null,
          },
          accessMode: readOnly ? pg.AccessMode.readOnly : null,
          queryTimeout: _timeout(timeout),
        ),
      );
    } catch (error, stackTrace) {
      throw translateDriverError(error, stackTrace, sql: '<transaction>');
    }
  }

  /// Borrows one connection from the pool for [action].
  ///
  /// All statements inside [action] run on the same connection, which is
  /// cheaper than a round trip through the pool per statement and lets you use
  /// session state such as temporary tables.
  @override
  Future<T> session<T>(
    Future<T> Function(QueryExecutor session) action, {
    Duration? timeout,
  }) async {
    await _executorOrOpen();
    try {
      return await _pool!.run<T>(
        (session) => action(SessionQueryExecutor(session)),
        settings: pg.SessionSettings(queryTimeout: _timeout(timeout)),
      );
    } catch (error, stackTrace) {
      throw translateDriverError(error, stackTrace, sql: '<session>');
    }
  }

  Future<T> _run<T>(
    Future<T> Function(SessionQueryExecutor executor, Duration? timeout)
    action, {
    Duration? timeout,
  }) async => action(await _executorOrOpen(), _timeout(timeout));

  Future<SessionQueryExecutor> _executorOrOpen() async {
    if (_isClosed) {
      throw const TikalDatabaseClosedException(
        'This PostgresConnection has been closed and can no longer run statements. '
        'Create a new instance, or call open() on one that is still unused.',
      );
    }
    if (!isOpen) {
      await open();
    }
    return _executor!;
  }

  Duration? _timeout(Duration? requested) => requested ?? config.queryTimeout;

  @override
  String toString() =>
      'PostgresConnection(${config.describe()}, open: $isOpen)';
}

/// Builds the driver endpoint for [config].
pg.Endpoint _endpoint(PostgresConfig config) => pg.Endpoint(
  host: config.host,
  port: config.port,
  database: config.database,
  username: config.username,
  password: config.password,
);

/// Builds the driver pool settings for [config].
pg.PoolSettings _poolSettings(PostgresConfig config) => pg.PoolSettings(
  maxConnectionCount: config.maxConnections,
  connectTimeout: config.connectTimeout,
  queryTimeout: config.queryTimeout,
  applicationName: config.applicationName,
  sslMode: switch (config.sslMode) {
    PostgresSslMode.disable => pg.SslMode.disable,
    PostgresSslMode.require => pg.SslMode.require,
    PostgresSslMode.verifyFull => pg.SslMode.verifyFull,
  },
);
