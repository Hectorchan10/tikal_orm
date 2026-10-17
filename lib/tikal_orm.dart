/// TikalORM — a type-safe PostgreSQL and SQLite ORM for Dart.
///
/// The connection layer provides configuration, pooling/transactions,
/// parameterised statements and result mapping. On top of it sit the model
/// layer (`TikalModel`, typed `ModelColumn` metadata, `TableDefinition`,
/// `Repository<T>`) and the fluent `QueryBuilder<T>`:
///
/// ```dart
/// import 'package:tikal_orm/tikal_orm.dart';
///
/// final db = TikalDatabase(PostgresConfig.fromEnvironment());
///
/// final users = await User.query(db)
///     .where(UserColumns.active.equals(true))
///     .orderBy(UserColumns.name)
///     .get();
///
/// // Raw SQL is always available on the same executor.
/// final rows = await db.query(
///   'SELECT id, email FROM users WHERE active = \$1 ORDER BY email',
///   parameters: [true],
/// );
///
/// await db.close();
/// ```
///
/// Annotated models can generate typed `User_` column holders with
/// `dart run tikal_orm:tikal generate`; manual metadata remains supported.
library;

export 'src/config/database_config.dart';
export 'src/config/postgres_config.dart';
export 'src/config/sqlite_config.dart';
export 'src/config/mysql_config.dart';
export 'src/config/sql_type.dart';
export 'src/errors/tikal_exceptions.dart';
export 'src/executor/query_executor.dart';
export 'src/executor/query_result.dart';
export 'src/executor/transaction_isolation.dart';
export 'src/model/column_definition.dart';
export 'src/model/decoders.dart';
export 'src/model/model_column.dart';
export 'src/model/table_definition.dart';
export 'src/model/tikal_model.dart';
export 'src/model/model_state.dart';
export 'src/model/model_registry.dart';
export 'src/params/sql_param.dart';
export 'src/query/order_by.dart';
export 'src/query/query_builder.dart';
export 'src/query/quoting.dart';
export 'src/query/sql_predicate.dart';
export 'src/query/sql_writer.dart';
export 'src/repository/repository.dart';
export 'src/tikal_database.dart';
export 'src/tikal.dart';

export 'src/model/annotations.dart';
export 'src/seeding/seeder.dart';
export 'src/seeding/seeder_registry.dart';
export 'src/model/relations.dart';
export 'src/schema/schema.dart';
export 'src/schema/schema_inspector.dart';
export 'src/schema/migration.dart';

@Deprecated(
  'Import package:tikal_orm/postgres.dart for PostgreSQL-specific bindings.',
)
export 'src/executor/postgres_params.dart';

/// Version of the TikalORM package.
const String tikalOrmVersion = '0.1.0';
