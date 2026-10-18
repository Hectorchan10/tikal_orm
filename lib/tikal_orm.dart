/// TikalORM: a type-safe ORM for PostgreSQL, SQLite and MySQL/MariaDB.
///
/// Generate mappings before compiling the consuming application, then import
/// its generated entry point to configure models automatically. Configuration
/// opens a connection; it never generates code or changes database tables.
///
/// ```dart
/// import 'models/user.dart';
/// import 'tikal.dart';
///
/// Future<void> main() async {
///   await Tikal.configure(database: SqliteConfig(path: 'app.db'));
///   try {
///     final user = await Tikal.model<User>().save(User(name: 'Ada', email: 'ada@example.com'));
///     final found = await Tikal.model<User>().findById(user.id!);
///     final all = await Tikal.model<User>().findAll();
///     final matching = await Tikal.model<User>().query()
///         .where(User_.name.equals('Ada'))
///         .get();
///   } finally {
///     await Tikal.close();
///   }
/// }
/// ```
///
/// The tables must already exist. Values are bound, never interpolated into
/// SQL. PostgreSQL-specific parameter bindings require the optional
/// `package:tikal_orm/postgres.dart` entry point.
library;

export 'src/config/database_config.dart';
export 'src/config/postgres_config.dart';
export 'src/config/sqlite_config.dart';
export 'src/config/mysql_config.dart';
export 'src/sql/sql_type.dart';
export 'src/errors/tikal_exceptions.dart';
export 'src/database/query_executor.dart';
export 'src/database/query_result.dart';
export 'src/database/query_listener.dart' hide QueryObservers;
export 'src/database/transaction_isolation.dart';
export 'src/model/metadata/column_definition.dart';
export 'src/model/conversion/decoders.dart';
export 'src/model/metadata/model_column.dart';
export 'src/model/metadata/table_definition.dart';
export 'src/model/model_state.dart' hide snapshotValues, snapshotEquals;
export 'src/model/metadata/model_registry.dart';
export 'src/sql/sql_param.dart';
export 'src/query/expressions/order_by.dart';
export 'src/query/query_builder.dart';
export 'src/query/sql/quoting.dart';
export 'src/query/expressions/sql_predicate.dart';
export 'src/query/sql/sql_writer.dart';
export 'src/repository/repository.dart';
export 'src/database/tikal_database.dart';
export 'src/tikal.dart';

export 'src/model/annotations.dart';
export 'src/model/conversion/type_converter.dart';
export 'src/model/conversion/converters.dart';
export 'src/sql/mysql/mysql_types.dart';
export 'src/seeding/seeder.dart';
export 'src/seeding/seeder_registry.dart';
export 'src/model/relations/relations.dart';
export 'src/model/relations/many_to_many_relation.dart';
export 'src/model/relations/many_to_many_handle.dart';
export 'src/schema/schema.dart';
export 'src/schema/schema_inspector.dart';
export 'src/schema/migration.dart';

/// Version of the TikalORM package.
const String tikalOrmVersion = '0.2.0';
