// Executor
import 'query_result.dart';
import 'query_executor.dart';

// Params
import '../params/named_params.dart';

/// Named binding template. SQLite overrides execute to keep updatedRows.
mixin NamedQueryMixin implements QueryExecutor {
  bool get mysqlNamedParameters => false;
  @override
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) {
    final statement = rewriteNamedParameters(
      sql,
      parameters,
      mysql: mysqlNamedParameters,
    );
    return query(
      statement.sql,
      parameters: statement.parameters,
      timeout: timeout,
    );
  }

  @override
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) {
    final statement = rewriteNamedParameters(
      sql,
      parameters,
      mysql: mysqlNamedParameters,
    );
    return execute(
      statement.sql,
      parameters: statement.parameters,
      timeout: timeout,
    );
  }

  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) async =>
      (await query(sql, parameters: parameters, timeout: timeout)).affectedRows;
}
