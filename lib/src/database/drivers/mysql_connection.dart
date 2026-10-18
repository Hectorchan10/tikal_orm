import 'dart:io';
import 'dart:async';

import 'package:mysql_dart/exception.dart' as mysql;
import 'package:mysql_dart/mysql_dart.dart' as mysql;
import 'package:synchronized/synchronized.dart';

// Database
import '../query_result.dart';
import '../query_executor.dart';
import '../transaction_isolation.dart';

// Config
import '../../config/mysql_config.dart';

// SQL
import '../../sql/mysql/mysql_params.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Database
import '../internal/named_query_mixin.dart';
import '../internal/database_connection.dart';

/// Pooled MySQL/MariaDB connections. Every physical session uses UTC,
/// utf8mb4 and strict writes; no ANSI_QUOTES or implicit global transaction.
final class MysqlConnection with NamedQueryMixin implements DatabaseConnection {
  /// Creates a lazy MySQL/MariaDB pool for the supplied settings.
  MysqlConnection(this.config);

  /// Immutable settings used to initialize this engine connection.
  final MysqlConfig config;
  final Object _scopeKey = Object();
  final Set<Future<void>> _pending = {};
  mysql.MySQLConnectionPool? _pool;
  Future<void>? _opening;
  bool _closed = false;

  @override
  SqlDialect get dialect => SqlDialect.mysql;
  @override
  bool get mysqlNamedParameters => true;
  @override
  bool get isOpen => _pool != null && !_closed;

  void _checkOpen() {
    if (_closed) {
      throw const TikalDatabaseClosedException(
        'This MySQL database has been closed.',
      );
    }
  }

  @override
  Future<void> open() {
    _checkOpen();
    if (isOpen) return Future.value();
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<void> _open() async {
    final pool = mysql.MySQLConnectionPool(
      host: config.host,
      port: config.port,
      userName: config.username,
      password: config.password ?? '',
      databaseName: config.database,
      maxConnections: config.maxConnections,
      secure: config.secure,
      collation: config.collation,
      timeoutMs: config.connectTimeout.inMilliseconds,
      timeZone: '+00:00',
      onConnectionOpen: (connection) async {
        await connection.execute(
          'SET NAMES utf8mb4 COLLATE ${config.collation}',
        );
        await connection.execute(
          "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION'",
        );
      },
    );
    try {
      await pool.withConnection((connection) => connection.execute('SELECT 1'));
      _pool = pool;
    } catch (_) {
      await pool.close();
      // Connection errors must never echo credentials supplied to the driver.
      throw TikalConnectionException(
        'Could not connect to MySQL at ${config.describe()}.',
      );
    }
  }

  @override
  Future<void> close({bool force = false}) async {
    _closed = true;
    try {
      await _opening;
    } on TikalConnectionException {
      // Failed initialization already released its pool.
    }
    final pool = _pool;
    if (!force) await Future.wait(_pending.toList());
    _pool = null;
    await pool?.close();
  }

  Future<T> _borrow<T>(
    Future<T> Function(_MysqlExecutor) action,
    Duration? timeout,
  ) async {
    await open();
    _checkOpen();
    final done = Completer<void>();
    _pending.add(done.future);
    try {
      return await _pool!.withConnection((connection) async {
        final executor = _MysqlExecutor(
          connection,
          timeout ?? config.queryTimeout,
        );
        try {
          return await action(executor);
        } finally {
          executor.active = false;
        }
      });
    } catch (error, stack) {
      translateMysqlError(error, stack, sql: '<session>');
    } finally {
      _pending.remove(done.future);
      done.complete();
    }
  }

  @override
  Future<bool> ping() async {
    if (!isOpen) return false;
    try {
      await query('SELECT 1', timeout: const Duration(seconds: 5));
      return true;
    } on TikalException {
      return false;
    }
  }

  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => _borrow(
    (executor) => executor.query(sql, parameters: parameters),
    timeout,
  );

  @override
  Future<T> session<T>(
    Future<T> Function(QueryExecutor) action, {
    Duration? timeout,
  }) {
    final scope = Zone.current[_scopeKey];
    if (scope is _MysqlExecutor && scope.active) return action(scope);
    return _borrow(
      (executor) =>
          runZoned(() => action(executor), zoneValues: {_scopeKey: executor}),
      timeout,
    );
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) => session(
    (executor) => (executor as _MysqlExecutor).transaction(
      action,
      isolation: isolation,
      readOnly: readOnly,
      timeout: timeout,
    ),
    timeout: timeout,
  );
}

/// A borrowed connection, invalidated before returning it to the pool.
final class _MysqlExecutor
    with NamedQueryMixin
    implements QueryExecutor, TransactionExecutor, TransactionStateExecutor {
  _MysqlExecutor(this.connection, this.timeout);
  final mysql.MySQLConnection connection;
  final Duration? timeout;
  bool active = true;
  int _depth = 0;
  @override
  bool get isInTransaction => _depth > 0;
  int _savepoint = 0;
  final Lock _lock = Lock();
  @override
  SqlDialect get dialect => SqlDialect.mysql;
  @override
  bool get mysqlNamedParameters => true;

  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) async {
    if (!active || !connection.connected) {
      throw const TikalDatabaseClosedException(
        'The MySQL session is no longer active.',
      );
    }
    final values = [
      for (final (index, value) in parameters.indexed)
        mysqlParameter(value, index),
    ];
    return _lock.synchronized(() async {
      try {
        final result = await connection.execute(
          sql,
          values.isEmpty ? null : values,
          false,
          timeout ?? this.timeout,
        );
        return QueryResult(
          rows: [for (final row in result.rows) _mapRow(row)],
          affectedRows: _exactInt(result.affectedRows),
          lastInsertId: result.lastInsertID == BigInt.zero
              ? null
              : _exactInt(result.lastInsertID),
        );
      } catch (error, stack) {
        // Driver timeouts only stop waiting. Discard the connection so a still
        // executing command cannot leak into a subsequent borrower/transaction.
        if (error is mysql.MySQLClientException) await connection.close();
        translateMysqlError(error, stack, sql: sql, parameters: parameters);
      }
    });
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) async {
    final nested = _depth > 0;
    if (nested && (isolation != null || readOnly)) {
      throw const TikalUnsupportedException(
        'A savepoint cannot change isolation or access mode.',
      );
    }
    final savepoint = 'tikal_${_savepoint++}';
    if (!nested && isolation != null) {
      final level = switch (isolation) {
        TransactionIsolation.readCommitted => 'READ COMMITTED',
        TransactionIsolation.repeatableRead => 'REPEATABLE READ',
        TransactionIsolation.serializable => 'SERIALIZABLE',
      };
      await execute('SET TRANSACTION ISOLATION LEVEL $level', timeout: timeout);
    }
    await execute(
      nested
          ? 'SAVEPOINT $savepoint'
          : 'START TRANSACTION${readOnly ? ' READ ONLY' : ''}',
      timeout: timeout,
    );
    _depth++;
    try {
      final result = await action(this);
      await execute(
        nested ? 'RELEASE SAVEPOINT $savepoint' : 'COMMIT',
        timeout: timeout,
      );
      return result;
    } catch (_) {
      try {
        await execute(nested ? 'ROLLBACK TO SAVEPOINT $savepoint' : 'ROLLBACK');
        if (nested) await execute('RELEASE SAVEPOINT $savepoint');
      } catch (_) {
        // Preserve the callback error; discard a session with uncertain state.
        await connection.close();
      }
      rethrow;
    } finally {
      _depth--;
    }
  }
}

int _exactInt(BigInt value) {
  final result = value.toInt();
  if (BigInt.from(result) != value) {
    throw const TikalUnsupportedException(
      'MySQL integer exceeds Dart int range.',
    );
  }
  return result;
}

TikalRow _mapRow(mysql.ResultSetRow row) {
  final values = row.typedAssoc();
  return TikalRow(
    columnNames: values.keys.toList(),
    values: [
      for (final value in values.values)
        value is DateTime
            ? DateTime.utc(
                value.year,
                value.month,
                value.day,
                value.hour,
                value.minute,
                value.second,
                value.millisecond,
                value.microsecond,
              )
            : value,
    ],
  );
}

/// mysql_dart 3.0 exposes a numeric server code, but no SQLSTATE. Preserve
/// the code as errorCode; sqlState remains absent instead of guessing one.
Never translateMysqlError(
  Object error,
  StackTrace stack, {
  required String sql,
  Object? parameters,
}) {
  if (error is TikalException) {
    Error.throwWithStackTrace(error, stack);
  }
  if (error is mysql.MySQLServerException) {
    if ({1044, 1045, 2002, 2003, 2006, 2013}.contains(error.errorCode)) {
      throw const TikalConnectionException(
        'MySQL connection or authentication failed.',
      );
    }
    final create = switch (error.errorCode) {
      1062 || 1586 => TikalUniqueViolation.new,
      1451 || 1452 => TikalForeignKeyViolation.new,
      1048 || 1364 => TikalNotNullViolation.new,
      _ => TikalQueryException.new,
    };
    throw create(
      sql: sql,
      parameters: parameters,
      serverMessage: error.message,
      errorCode: error.errorCode,
      cause: error,
    );
  }
  if (error is mysql.MySQLClientException ||
      error is SocketException ||
      error is TimeoutException) {
    throw TikalConnectionException(
      'The MySQL connection failed while running a statement.',
      cause: error,
    );
  }
  if (error is ArgumentError) {
    throw TikalParameterException(
      'MySQL rejected the bound parameters.',
      cause: error,
    );
  }
  Error.throwWithStackTrace(
    TikalQueryException(sql: sql, parameters: parameters, cause: error),
    stack,
  );
}
