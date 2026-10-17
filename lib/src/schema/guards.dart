// Query
import '../query/dialect.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';

/// Guard shared by PostgreSQL catalog and migration operations.
void requirePostgresSchema(QueryExecutor executor) {
  if (!dialectOf(executor).strategy.supportsPostgresSchema) {
    throw const TikalUnsupportedException(
      'Migrations and schema inspection are only supported on PostgreSQL. Supply reviewed engine-specific DDL explicitly.',
    );
  }
}
