// Database
import 'query_result.dart';
import 'transaction_isolation.dart';

/// Bound SQL execution shared by databases, sessions and transactions.
/// PostgreSQL uses $n placeholders; SQLite/MySQL use ?. Named queries use @name.
/// Implementations preserve typed parameters and never interpolate values.
abstract interface class QueryExecutor {
  /// SQL syntax and binding rules used by this executor.
  SqlDialect get dialect;

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
enum SqlDialect {
  /// PostgreSQL identifiers, numbered placeholders and native typed values.
  postgres,

  /// SQLite identifiers, positional placeholders and portable bound values.
  sqlite,

  /// MySQL/MariaDB backtick identifiers and positional placeholders.
  mysql,
}

/// Explicit transaction capability, also available on borrowed MySQL sessions.
abstract interface class TransactionExecutor {
  /// Runs the callback with a transaction-bound executor, committing on success.
  /// Errors propagate after rollback. Nested MySQL/SQLite transactions use savepoints;
  /// SQLite accepts isolation levels without changing its single serializable mode.
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  });
}

/// Optional state exposed by transaction-capable, borrowed executors.
/// Custom executors should implement this when transaction callbacks reuse an
/// executor that also implements TransactionExecutor, to avoid nested transactions.
abstract interface class TransactionStateExecutor {
  /// Whether operations currently participate in an active transaction.
  bool get isInTransaction;
}
