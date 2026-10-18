import 'package:sqlite3/sqlite3.dart' hide SqlType;
import 'package:synchronized/synchronized.dart';

// Database
import '../query_result.dart';
import '../query_executor.dart';

// SQL
import '../../sql/sql_type.dart';

// Database
import '../transaction_isolation.dart';

// Config
import '../../config/sqlite_config.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Database
import '../internal/named_query_mixin.dart';
import '../internal/database_connection.dart';

// SQL
import '../../sql/internal/portable_params.dart';

/// Owns one native SQLite handle, opened lazily and closed explicitly.
/// A per-connection lock serializes statements; transaction/session zones reuse
/// that lock, and nested transactions use savepoints.
final class SqliteConnection
    with NamedQueryMixin
    implements DatabaseConnection {
  /// Creates a handle for [config]. No connection is opened yet.
  SqliteConnection(this.config);

  /// The settings this database was created with.
  final SqliteConfig config;
  final Lock _lock = Lock(reentrant: true);
  int _transactionDepth = 0;

  Database? _database;
  bool _isClosed = false;
  Future<void>? _opening;
  int _savepointCounter = 0;

  /// SQLite always speaks its own placeholder and type rules.
  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  /// Whether the connection exists and has not been closed.
  @override
  bool get isOpen => _database != null && !_isClosed;

  /// Whether the database has not been opened yet, or has been closed.
  bool get isClosed => !isOpen;

  /// Opens the database file and applies the connection pragmas.
  ///
  /// Safe to call repeatedly: concurrent and later calls share the first
  /// attempt. Throws [TikalConnectionException] when the file cannot be opened,
  /// and [TikalDatabaseClosedException] once [close] was called.
  @override
  Future<void> open() {
    if (_isClosed) {
      throw const TikalDatabaseClosedException(
        'This SqliteConnection has been closed; create a new instance instead of reusing it.',
      );
    }
    if (isOpen) return Future<void>.value();
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    final Database database;
    try {
      database = config.path == ':memory:'
          ? sqlite3.openInMemory()
          : sqlite3.open(config.path);
    } on Object catch (error) {
      throw TikalConnectionException(
        'Could not open SQLite database ${config.describe()}. Cause: $error',
        cause: error,
      );
    }
    try {
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA busy_timeout = 5000');
    } on Object catch (error) {
      database.close();
      throw TikalConnectionException(
        'Could not initialize SQLite database ${config.describe()}. Cause: $error',
        cause: error,
      );
    }
    _database = database;
  }

  /// Returns `true` when the database answers `SELECT 1`.
  ///
  /// Useful for health checks such as Dart Frog's `/_health` route. Never
  /// throws: connection problems are reported as `false`.
  @override
  Future<bool> ping() async {
    final database = _database;
    if (database == null || _isClosed) return false;
    try {
      database.select('SELECT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Closes the connection and releases the native handle.
  ///
  /// The instance cannot be reopened afterwards: create a new `SqliteConnection`.
  /// SQLite closes synchronously; [force] does not change native cleanup.
  @override
  Future<void> close({bool force = false}) async {
    final database = _database;
    _database = null;
    _isClosed = true;
    database?.close();
  }

  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const <Object?>[],
    Duration? timeout,
  }) => _lock.synchronized(() async {
    final database = await _databaseOrOpen();
    try {
      return _mapResultSet(database.select(sql, _bindPositional(parameters)));
    } catch (error, stackTrace) {
      throw _translate(error, stackTrace, sql: sql, parameters: parameters);
    }
  });

  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const <Object?>[],
    Duration? timeout,
  }) => _lock.synchronized(() async {
    final database = await _databaseOrOpen();
    try {
      database.execute(sql, _bindPositional(parameters));
      return database.updatedRows;
    } catch (error, stackTrace) {
      throw _translate(error, stackTrace, sql: sql, parameters: parameters);
    }
  });

  /// Runs [action] inside a transaction.
  ///
  /// The transaction is committed when [action] completes and rolled back when
  /// it throws; the original error is rethrown either way. Nested calls join the
  /// current transaction through a savepoint. SQLite offers a single serializable
  /// transaction mode, so [isolation] is accepted but not applied; [readOnly]
  /// turns on `PRAGMA query_only` so writes are rejected.
  ///
  /// ```dart
  /// await db.transaction((tx) async {
  ///   await tx.execute('UPDATE accounts SET balance = balance - ? WHERE id = ?', parameters: [100, from]);
  ///   await tx.execute('UPDATE accounts SET balance = balance + ? WHERE id = ?', parameters: [100, to]);
  /// });
  /// ```
  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor tx) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) => _lock.synchronized(() async {
    final nested = _transactionDepth > 0;
    _transactionDepth++;
    try {
      return await (nested
          ? _nestedTransaction(action)
          : _runTransaction(action, readOnly: readOnly));
    } finally {
      _transactionDepth--;
    }
  });

  Future<T> _runTransaction<T>(
    Future<T> Function(QueryExecutor tx) action, {
    required bool readOnly,
  }) async {
    final database = await _databaseOrOpen();
    if (readOnly) database.execute('PRAGMA query_only = ON');
    try {
      database.execute(readOnly ? 'BEGIN' : 'BEGIN IMMEDIATE');
      try {
        final result = await action(this);
        database.execute('COMMIT');
        return result;
      } catch (_) {
        try {
          database.execute('ROLLBACK');
        } catch (_) {
          // The transaction may already be unwound; keep the original error.
        }
        rethrow;
      }
    } finally {
      if (readOnly) {
        try {
          database.execute('PRAGMA query_only = OFF');
        } catch (_) {
          // Closing semantics are best effort once the transaction is finished.
        }
      }
    }
  }

  Future<T> _nestedTransaction<T>(
    Future<T> Function(QueryExecutor tx) action,
  ) async {
    final database = _database;
    if (database == null || _isClosed) {
      throw const TikalDatabaseClosedException(
        'This SqliteConnection has been closed and can no longer run statements.',
      );
    }
    final name = 'tikal_savepoint_${_savepointCounter++}';
    database.execute('SAVEPOINT $name');
    try {
      final result = await action(this);
      database.execute('RELEASE $name');
      return result;
    } catch (_) {
      try {
        database.execute('ROLLBACK TO $name');
        database.execute('RELEASE $name');
      } catch (_) {
        // The savepoint may already be gone; keep the original error.
      }
      rethrow;
    }
  }

  /// Serializes [action] except when it runs inside a transaction or session on
  /// this connection, where the lock is already held.
  @override
  Future<T> session<T>(
    Future<T> Function(QueryExecutor session) action, {
    Duration? timeout,
  }) => _lock.synchronized(() => action(this));

  Future<Database> _databaseOrOpen() async {
    if (_isClosed) {
      throw const TikalDatabaseClosedException(
        'This SqliteConnection has been closed and can no longer run statements. '
        'Create a new instance, or call open() on one that is still unused.',
      );
    }
    if (!isOpen) {
      await open();
    }
    return _database!;
  }

  List<Object?> _bindPositional(List<Object?> values) => [
    for (final (index, value) in values.indexed) _sqliteParameter(value, index),
  ];

  @override
  String toString() => 'SqliteConnection(${config.describe()}, open: $isOpen)';
}

/// Converts a result set into a [QueryResult].
///
/// SQLite `SELECT` command tags report the number of rows just like
/// PostgreSQL, so `affectedRows` mirrors the row count (which also matches
/// `INSERT ... RETURNING`).
QueryResult _mapResultSet(ResultSet result) {
  final rows = <TikalRow>[
    for (final row in result)
      TikalRow(columnNames: result.columnNames, values: row.values),
  ];
  return QueryResult(rows: rows, affectedRows: rows.length);
}

Object? _sqliteParameter(Object? value, int? position) =>
    encodePortableParameter(
      value,
      engine: 'SQLite',
      position: position,
      dateTime: _sqliteDate,
    );

String _sqliteDate(SqlType? type, DateTime value) =>
    (type == SqlType.timestamp || type == SqlType.date ? value : value.toUtc())
        .toIso8601String();

/// Translates a driver error into the TikalORM hierarchy.
///
/// Errors that TikalORM did not produce (including exceptions thrown by user
/// callbacks inside a transaction) are rethrown untouched, preserving their
/// stack trace.
Never _translate(
  Object error,
  StackTrace stackTrace, {
  required String sql,
  Object? parameters,
}) {
  if (error is TikalException) {
    throw error;
  }
  if (error is SqliteException) {
    final code = error.resultCode;
    if (code == SqlError.SQLITE_BUSY ||
        code == SqlError.SQLITE_LOCKED ||
        code == SqlError.SQLITE_IOERR ||
        code == SqlError.SQLITE_CANTOPEN ||
        code == SqlError.SQLITE_NOTADB) {
      throw TikalConnectionException(
        'SQLite could not complete the statement.',
        cause: error,
      );
    }
    final create = switch (error.extendedResultCode) {
      SqlExtendedError.SQLITE_CONSTRAINT_UNIQUE ||
      SqlExtendedError.SQLITE_CONSTRAINT_PRIMARYKEY => TikalUniqueViolation.new,
      SqlExtendedError.SQLITE_CONSTRAINT_FOREIGNKEY =>
        TikalForeignKeyViolation.new,
      SqlExtendedError.SQLITE_CONSTRAINT_NOTNULL => TikalNotNullViolation.new,
      _ => TikalQueryException.new,
    };
    throw create(
      sql: sql,
      parameters: parameters,
      serverMessage: error.message,
      errorCode: error.extendedResultCode,
      detail: error.explanation,
      cause: error,
    );
  }
  if (error is ArgumentError) {
    throw TikalParameterException(
      'SQLite rejected the bound parameters.',
      cause: error,
    );
  }
  Error.throwWithStackTrace(
    TikalQueryException(sql: sql, parameters: parameters, cause: error),
    stackTrace,
  );
}
