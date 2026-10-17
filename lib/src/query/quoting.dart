// Query
import 'dialect.dart';

// Executor
import '../executor/query_executor.dart';

/// Quotes a SQL identifier for [dialect].
///
/// PostgreSQL and SQLite accept `"name"`; MySQL only treats double quotes as
/// string literals by default, so it needs `` `name` ``. Every table, column and
/// schema name that TikalORM writes into SQL goes through this function, so
/// reserved words (`user`, `order`, `select`, ...) and mixed-case names work
/// without surprises. The quote character is doubled to escape it.
String quotedIdentifier(
  String name, [
  SqlDialect dialect = SqlDialect.postgres,
]) => dialect.strategy.quote(name);
