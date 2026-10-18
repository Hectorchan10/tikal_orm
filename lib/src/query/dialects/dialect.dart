import 'package:meta/meta.dart';

// SQL
import '../sql/sql_writer.dart';
import '../../sql/sql_type.dart';

// Query
import '../expressions/order_by.dart';

// Database
import '../../database/query_executor.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Model
import '../../model/metadata/column_definition.dart';

part 'postgres_dialect.dart';
part 'sqlite_dialect.dart';
part 'mysql_dialect.dart';

/// SQL syntax and capabilities of one implemented engine.
@internal
abstract interface class Dialect {
  int get maxParameters;
  String get writeLockClause;
  void insertIgnore(SqlWriter writer, void Function() body);
  bool supports(SqlType type);
  String ddlType(SqlType type, {int? length, int? precision, int? scale});
  String quote(String name);
  String placeholder(int index);
  String qualifiedName(String name, String? schema);
  bool get supportsReturning;
  bool get generatesUuidOnClient;
  bool get supportsCaseSensitiveLike;
  bool get supportsPostgresSchema;
  String get emptyInsert;
  String get offsetOnlyPrefix;
  void writeLike(
    SqlWriter writer,
    ColumnDefinition column,
    String pattern, {
    required bool caseInsensitive,
    required bool negated,
  });
  void writeOrderTerm(
    SqlWriter writer,
    String column, {
    required bool descending,
    NullsOrder? nulls,
  });
  void upsertClause(
    SqlWriter writer,
    List<ColumnDefinition> conflicts,
    List<ColumnDefinition> updates, {
    String? primaryKey,
  });
}

/// Selects the implemented SQL strategy for an engine.
@internal
extension SqlDialectStrategy on SqlDialect {
  Dialect get strategy => switch (this) {
    SqlDialect.postgres => const PostgresDialect(),
    SqlDialect.sqlite => const SqliteDialect(),
    SqlDialect.mysql => const MysqlDialect(),
  };
}

void _validateDimensions(int? length, int? precision, int? scale) {
  if (length != null && length < 1 ||
      precision != null && precision < 1 ||
      scale != null && (precision == null || scale < 0 || scale > precision)) {
    throw ArgumentError('Invalid SQL length, precision or scale.');
  }
}
