// SQL
import '../../sql/sql_type.dart';

// Query
import '../../query/dialects/dialect.dart';

// Database
import '../../database/query_executor.dart';

/// Structural metadata about a single table column.
///
/// This is the model-independent view of a column: its name, SQL type
/// and constraints. The typed accessors that link a column to a model field
/// live in `ModelColumn`, which extends this class. Predicates and `ORDER BY`
/// clauses only depend on this base type, which keeps the query layer free of
/// any model dependency and avoids an import cycle.
class ColumnDefinition {
  /// Creates column metadata.
  const ColumnDefinition({
    required this.name,
    required this.sqlType,
    this.nullable = false,
    this.hasDefault = false,
    this.primaryKey = false,
    this.unique = false,
    this.autoIncrement = false,
    this.comment,
    this.encode,
    this.nativeTypes = const {},
    this.length,
    this.precision,
    this.scale,
  });

  /// Column name as it appears in the database, without quotes.
  final String name;

  /// SQL type used when binding this column's values.
  final SqlType sqlType;

  /// Whether SQL `NULL` is allowed in this column.
  final bool nullable;

  /// Whether the column has a server side default (`DEFAULT ...`).
  final bool hasDefault;

  /// Whether the column is part of the primary key.
  final bool primaryKey;

  /// Whether the column carries a `UNIQUE` constraint.
  final bool unique;

  /// Whether the database generates the value (`serial`, `identity`, ...).
  final bool autoIncrement;

  /// Optional human readable description.
  final String? comment;

  /// Optional conversion from a Dart value to its SQL representation.
  /// Null handling is owned by the encoder; converter-backed columns bypass null.
  final Object? Function(Object?)? encode;

  /// Returns the encoded value, preserving identity when there is no encoder.
  Object? encodeValue(Object? value) => encode == null ? value : encode!(value);

  /// Trusted native DDL declarations keyed by engine name; binding is unchanged.
  final Map<String, String> nativeTypes;

  /// Optional text/character length used by portable DDL mapping.
  final int? length;

  /// Optional decimal precision used by portable DDL mapping.
  final int? precision;

  /// Optional decimal scale used by portable DDL mapping.
  final int? scale;

  /// Returns opt-in native DDL, or the engine's portable type declaration.
  /// Throws TikalUnsupportedException if no mapping exists for this engine.
  String ddlTypeFor(SqlDialect dialect) =>
      nativeTypes[dialect.name] ??
      dialect.strategy.ddlType(
        sqlType,
        length: length,
        precision: precision,
        scale: scale,
      );

  /// Whether a value must be supplied by the application on insert.
  ///
  /// Columns with a default or generated value may be omitted.
  bool get required => !nullable && !hasDefault && !autoIncrement;

  @override
  String toString() =>
      '$runtimeType($name ${sqlType.sqlName}'
      '${nullable ? ', nullable' : ''}'
      '${primaryKey ? ', primary key' : ''})';
}
