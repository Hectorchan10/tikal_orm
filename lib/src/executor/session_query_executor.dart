import 'package:postgres/postgres.dart' as pg;

// Executor
import 'query_result.dart';
import 'query_executor.dart';
import 'postgres_params.dart';
import 'driver_result_mapper.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// A [QueryExecutor] backed by one PostgreSQL session (a pooled connection or a
/// transaction).
final class SessionQueryExecutor implements QueryExecutor {
  /// Wraps one driver session.
  SessionQueryExecutor(this._session);

  final pg.Session _session;

  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => _execute(sql, parameters, timeout: timeout);

  @override
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => _execute(sql, parameters, timeout: timeout);

  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) async => (await _execute(
    sql,
    parameters,
    ignoreRows: true,
    timeout: timeout,
  )).affectedRows;

  @override
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) async => (await _execute(
    sql,
    parameters,
    ignoreRows: true,
    timeout: timeout,
  )).affectedRows;

  Future<QueryResult> _execute(
    String sql,
    Object original, {
    bool ignoreRows = false,
    Duration? timeout,
  }) {
    final named = original is Map<String, Object?>;
    final parameters = named
        ? _bindNamed(original)
        : _bindPositional(original as List<Object?>);
    return _run(
      sql,
      named ? pg.Sql.named(sql) : sql,
      parameters,
      original,
      ignoreRows,
      timeout,
    );
  }

  Future<QueryResult> _run(
    String sql,
    Object query,
    Object parameters,
    Object original,
    bool ignoreRows,
    Duration? timeout,
  ) async {
    try {
      return mapDriverResult(
        await _session.execute(
          query,
          parameters: parameters,
          ignoreRows: ignoreRows,
          timeout: timeout,
        ),
      );
    } catch (error, stackTrace) {
      throw translateDriverError(
        error,
        stackTrace,
        sql: sql,
        parameters: original,
      );
    }
  }

  /// Binds every value, remembering the position for error reporting.
  List<Object?> _bindPositional(List<Object?> values) => [
    for (final (index, value) in values.indexed)
      bindParameter(value, position: index),
  ];

  /// Binds every named value, remembering the name for error reporting.
  Map<String, Object?> _bindNamed(Map<String, Object?> parameters) => {
    for (final entry in parameters.entries)
      entry.key: _bindNamedValue(entry.key, entry.value),
  };

  Object? _bindNamedValue(String name, Object? value) {
    try {
      return bindParameter(value);
    } on TikalParameterException catch (error) {
      throw TikalParameterException(
        'Invalid value for parameter "@$name": ${error.message}',
        value: error.value,
        cause: error.cause,
      );
    }
  }

  @override
  String toString() => 'SessionQueryExecutor(isOpen: ${_session.isOpen})';
}

/// Translates a driver error into the TikalORM hierarchy.
///
/// Errors that TikalORM did not produce (including exceptions thrown by user
/// callbacks inside a transaction) are rethrown untouched, preserving their
/// stack trace.
Never translateDriverError(
  Object error,
  StackTrace stackTrace, {
  required String sql,
  Object? parameters,
}) {
  if (error is pg.ServerException) {
    throw TikalQueryException(
      sql: sql,
      parameters: parameters,
      serverMessage: error.message,
      sqlState: error.code,
      detail: error.detail,
      hint: error.hint,
      table: error.tableName,
      column: error.columnName,
      constraint: error.constraintName,
      cause: error,
    );
  }
  if (error is TikalException) {
    throw error;
  }
  if (error is pg.PgException) {
    throw TikalConnectionException(
      'The connection to PostgreSQL failed while running the statement.',
      cause: error,
    );
  }
  if (error is ArgumentError) {
    throw TikalParameterException(
      'PostgreSQL rejected the bound parameters: ${error.message}',
      cause: error,
    );
  }
  Error.throwWithStackTrace(error, stackTrace);
}
