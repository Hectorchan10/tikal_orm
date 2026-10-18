// SQL
import '../sql_type.dart';
import 'native_sql_value.dart';
import '../../query/sql/sql_writer.dart';

// Query
import '../../query/dialects/dialect.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Model
import '../../model/metadata/model_column.dart';

// Query
import '../../query/expressions/sql_predicate.dart';

// Model
import '../../model/metadata/column_definition.dart';

/// Native PostgreSQL array predicates with typed, bound array values.
extension PostgresArrayPredicates<T, V> on ModelColumn<T, List<V>> {
  /// Tests whether the array contains every supplied value, using @>.
  /// Throws [TikalUnsupportedException] outside PostgreSQL or for other element types.
  SqlPredicate<T> arrayContains(Iterable<V> values) =>
      _arrayPredicate<T, V>(this, values, '@>');

  /// Tests whether arrays share any supplied element, using &&.
  /// Throws [TikalUnsupportedException] outside PostgreSQL or for other element types.
  SqlPredicate<T> arrayOverlaps(Iterable<V> values) =>
      _arrayPredicate<T, V>(this, values, '&&');
}

SqlPredicate<T> _arrayPredicate<T, V>(
  ColumnDefinition column,
  Iterable<V> values,
  String operator,
) {
  final encoded = V == String
      ? NativeSqlValue(
          PostgresValueType.textArray,
          List<String>.unmodifiable(values.cast<String>()),
        )
      : V == int
      ? NativeSqlValue(
          PostgresValueType.integerArray,
          List<int>.unmodifiable(values.cast<int>()),
        )
      : throw const TikalUnsupportedException(
          'PostgreSQL array predicates support String or int elements.',
        );
  return _ArrayPredicate(column, encoded, operator);
}

final class _ArrayPredicate<T> extends SqlPredicate<T> {
  const _ArrayPredicate(this.column, this.value, this.operator);
  final ColumnDefinition column;
  final NativeSqlValue value;
  final String operator;
  @override
  void writeTo(SqlWriter writer) {
    _requirePostgres(writer);
    writer
      ..writeIdentifier(column.name)
      ..write(' $operator ');
    writer.bindTyped(column.sqlType, value);
  }
}

/// Native PostgreSQL JSON-path existence checks, with a bound path.
extension PostgresJsonPredicates<T, V> on ModelColumn<T, V> {
  /// Tests whether a SQL/JSON path finds a value in the JSON document.
  /// Throws [TikalUnsupportedException] outside PostgreSQL or on non-JSON columns.
  SqlPredicate<T> jsonPath(String path) {
    if (sqlType != SqlType.json && sqlType != SqlType.jsonb) {
      throw const TikalUnsupportedException('jsonPath requires a JSON column.');
    }
    return _JsonPathPredicate<T>(this, path);
  }
}

final class _JsonPathPredicate<T> extends SqlPredicate<T> {
  const _JsonPathPredicate(this.column, this.path);
  final ColumnDefinition column;
  final String path;
  @override
  void writeTo(SqlWriter writer) {
    _requirePostgres(writer);
    writer.write('jsonb_path_exists(CAST(');
    writer.writeIdentifier(column.name);
    writer.write(' AS jsonb), CAST(');
    writer.bindTyped(SqlType.text, path);
    writer.write(' AS jsonpath))');
  }
}

void _requirePostgres(SqlWriter writer) {
  if (!writer.dialect.strategy.supportsPostgresSchema) {
    throw const TikalUnsupportedException(
      'This predicate requires PostgreSQL.',
    );
  }
}
