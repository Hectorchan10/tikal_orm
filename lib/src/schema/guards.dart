// Query
import '../query/dialects/dialect.dart';

// Database
import '../database/query_executor.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// Guard shared by PostgreSQL catalog and migration operations.
void requirePostgresSchema(QueryExecutor executor) {
  if (!executor.dialect.strategy.supportsPostgresSchema) {
    throw const TikalUnsupportedException(
      'Migrations and schema inspection are only supported on PostgreSQL. Supply reviewed engine-specific DDL explicitly.',
    );
  }
}
