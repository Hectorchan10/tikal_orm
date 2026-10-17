// Executor
import 'query_result.dart';
import 'transaction_isolation.dart';

/// Bound SQL execution shared by databases, sessions and transactions.
/// PostgreSQL uses $n placeholders; SQLite/MySQL use ?. Named queries use @name.
/// Implementations preserve typed parameters and never interpolate values.
abstract interface class QueryExecutor {
  /// Runs [sql] and returns the rows it produced.
  ///
  /// Use the engine's placeholders (`$1`, `$2`, ... on PostgreSQL, `?` on
  /// SQLite and MySQL) and pass the matching values in [parameters]. Values
  /// wrapped in `SqlParam` keep an explicit type.
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters,
    Duration? timeout,
  });

  /// Runs [sql] with `@name` placeholders taken from [parameters].
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters,
    Duration? timeout,
  });

  /// Runs a statement and returns the number of affected rows.
  ///
  /// Rows returned by `RETURNING` are discarded; use [query] when you need
  /// them.
  Future<int> execute(
    String sql, {
    List<Object?> parameters,
    Duration? timeout,
  });

  /// Like [execute], with `@name` placeholders.
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters,
    Duration? timeout,
  });
}

/// SQL differences of engines with real implementations.
enum SqlDialect { postgres, sqlite, mysql }

/// Optional capability so existing custom executors remain source compatible.
abstract interface class DialectExecutor {
  SqlDialect get dialect;
}

/// Existing/custom executors retain PostgreSQL SQL unless they opt in.
SqlDialect dialectOf(QueryExecutor executor) => executor is DialectExecutor
    ? (executor as DialectExecutor).dialect
    : SqlDialect.postgres;

/// Explicit transaction capability, also available on borrowed MySQL sessions.
abstract interface class TransactionExecutor {
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  });
}
