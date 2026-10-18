// Database
import 'query_result.dart';
import 'query_executor.dart';
import 'query_listener.dart';
import 'transaction_isolation.dart';

// Config
import '../config/mysql_config.dart';
import '../config/sqlite_config.dart';

// Database
import 'drivers/mysql_connection.dart';

// Config
import '../config/database_config.dart';
import '../config/postgres_config.dart';

// Database
import 'drivers/sqlite_connection.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Database
import 'drivers/postgres_connection.dart';
import 'internal/database_connection.dart';

/// Database handle selected directly from its engine-specific configuration.
/// Connections are reused until explicitly closed. Configuration selects the
/// engine; callers never pass a separate dialect flag. PostgreSQL/MySQL use pools
/// and SQLite owns one native handle. Closing is terminal, including while open
/// is pending. Driver failures are translated at the engine boundary.
final class TikalDatabase implements DatabaseConnection {
  /// Selects a lazy engine connection from its typed configuration.
  /// Throws TikalConfigurationException for an unsupported configuration type.
  TikalDatabase(this.config)
    : _connection = switch (config) {
        PostgresConfig config => PostgresConnection(config),
        SqliteConfig config => SqliteConnection(config),
        MysqlConfig config => MysqlConnection(config),
        _ => throw const TikalConfigurationException(
          'Unsupported database configuration.',
        ),
      };

  /// Common settings. Narrow to PostgresConfig for PostgreSQL-specific fields.
  final DatabaseConfig config;
  final DatabaseConnection _connection;
  final _observers = QueryObservers();
  late final QueryExecutor _executor = _observers.wrap(_connection);

  /// Registers a connection-scoped observer and returns an idempotent remover.
  /// Includes explicit sessions and transactions; close removes all observers.
  /// Listener failures never replace query results or errors. Bind sensitive
  /// values: literal secrets embedded in raw SQL remain visible in event.sql.
  void Function() onQuery(QueryListener listener) => _observers.add(listener);

  @override
  SqlDialect get dialect => _connection.dialect;
  @override
  bool get isOpen => _connection.isOpen;

  /// Whether no initialized connection is available, including unused handles.
  bool get isClosed => !isOpen;
  @override
  Future<void> open() => _connection.open();
  @override
  Future<bool> ping() => _connection.ping();
  @override
  Future<void> close({bool force = false}) async {
    try {
      await _connection.close(force: force);
    } finally {
      _observers.clear();
    }
  }

  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => _executor.query(sql, parameters: parameters, timeout: timeout);
  @override
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => _executor.queryNamed(sql, parameters: parameters, timeout: timeout);
  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => _executor.execute(sql, parameters: parameters, timeout: timeout);
  @override
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => _executor.executeNamed(sql, parameters: parameters, timeout: timeout);
  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) => (_executor as TransactionExecutor).transaction(
    action,
    isolation: isolation,
    readOnly: readOnly,
    timeout: timeout,
  );
  @override
  Future<T> session<T>(
    Future<T> Function(QueryExecutor) action, {
    Duration? timeout,
  }) => _connection.session(
    (session) => action(_observers.wrap(session)),
    timeout: timeout,
  );
  @override
  String toString() => 'TikalDatabase(${config.describe()}, open: $isOpen)';
}
