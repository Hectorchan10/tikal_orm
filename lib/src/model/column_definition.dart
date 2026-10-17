// Config
import '../config/sql_type.dart';

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
