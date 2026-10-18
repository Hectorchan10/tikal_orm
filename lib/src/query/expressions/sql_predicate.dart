// SQL
import '../sql/sql_writer.dart';

// Model
import '../dialects/dialect.dart';

// SQL
import '../sql/raw_placeholders.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Model
import '../../model/metadata/column_definition.dart';

/// Comparison operators used by [ColumnComparison].
enum SqlOperator {
  /// `=`
  equal('='),

  /// `<>`
  notEqual('<>'),

  /// `<`
  lessThan('<'),

  /// `<=`
  lessThanOrEqual('<='),

  /// `>`
  greaterThan('>'),

  /// `>=`
  greaterThanOrEqual('>=');

  const SqlOperator(this.sql);

  /// The SQL spelling of the operator.
  final String sql;
}

/// A boolean expression over a model `TModel`.
///
/// Predicates know how to render themselves into a [SqlWriter]; they never
/// contain values inline, so every comparison is safely parameterised. They can
/// be combined with [and], [or] and [negate]:
///
/// ```dart
/// final predicate = User_.active.equals(true).and(User_.age.greaterThan(18));
/// // active = $1 AND age > $2
/// ```
abstract class SqlPredicate<TModel> {
  /// Const constructor for subclasses.
  const SqlPredicate();

  /// Renders this expression into [writer], preserving raw/composite grouping.
  void writeTo(SqlWriter writer);

  /// `this AND [other]`.
  SqlPredicate<TModel> and(SqlPredicate<TModel> other) =>
      AndPredicate<TModel>(this, other);

  /// `this OR [other]`.
  SqlPredicate<TModel> or(SqlPredicate<TModel> other) =>
      OrPredicate<TModel>(this, other);

  /// `NOT this`.
  SqlPredicate<TModel> negate() => NotPredicate<TModel>(this);

  /// A predicate that is always `true`.
  static SqlPredicate<TModel> alwaysTrue<TModel>() =>
      RawSqlPredicate<TModel>('TRUE');

  /// A predicate that is always `false`.
  static SqlPredicate<TModel> alwaysFalse<TModel>() =>
      RawSqlPredicate<TModel>('FALSE');

  @override
  String toString() {
    final writer = SqlWriter();
    writeTo(writer);
    return '$runtimeType(${writer.sql})';
  }
}

/// `column <op> value`.
final class ColumnComparison<TModel, TValue> extends SqlPredicate<TModel> {
  /// Compares [column] with [value] using [operator].
  const ColumnComparison(this.column, this.operator, this.value);

  /// The column being compared.
  final ColumnDefinition column;

  /// The comparison operator.
  final SqlOperator operator;

  /// The value on the right hand side.
  final TValue value;

  @override
  void writeTo(SqlWriter writer) {
    writer.writeIdentifier(column.name);
    writer.write(' ${operator.sql} ');
    writer.bindTyped(column.sqlType, column.encodeValue(value));
  }
}

/// `column IS NULL` / `column IS NOT NULL`.
final class ColumnNullCheck<TModel> extends SqlPredicate<TModel> {
  /// Checks [column] for `NULL`.
  const ColumnNullCheck(this.column, {required this.isNull});

  /// The column being checked.
  final ColumnDefinition column;

  /// Whether the predicate matches `NULL` (`true`) or `NOT NULL` (`false`).
  final bool isNull;

  @override
  void writeTo(SqlWriter writer) {
    writer.writeIdentifier(column.name);
    writer.write(isNull ? ' IS NULL' : ' IS NOT NULL');
  }
}

/// `column IN (...)` / `column NOT IN (...)`.
final class ColumnInList<TModel, TValue> extends SqlPredicate<TModel> {
  /// Matches rows where [column] is one of [values].
  ///
  /// An empty [values] list renders a constant instead of the invalid
  /// `IN ()`: `FALSE` for `IN`, `TRUE` for `NOT IN`.
  const ColumnInList(this.column, this.values, {this.negated = false});

  /// The column being tested.
  final ColumnDefinition column;

  /// The candidate values.
  final List<TValue> values;

  /// Whether this is a `NOT IN` test.
  final bool negated;

  @override
  void writeTo(SqlWriter writer) {
    if (values.isEmpty) {
      writer.write(negated ? 'TRUE' : 'FALSE');
      return;
    }
    writer.writeIdentifier(column.name);
    writer.write(negated ? ' NOT IN (' : ' IN (');
    for (final (index, value) in values.indexed) {
      if (index > 0) writer.write(', ');
      writer.bindTyped(column.sqlType, column.encodeValue(value));
    }
    writer.write(')');
  }
}

/// `column BETWEEN lower AND upper` / `column NOT BETWEEN lower AND upper`.
final class ColumnBetween<TModel, TValue> extends SqlPredicate<TModel> {
  /// Matches rows where [column] is in the inclusive range [lower] to [upper].
  const ColumnBetween(
    this.column,
    this.lower,
    this.upper, {
    this.negated = false,
  });

  /// The column being tested.
  final ColumnDefinition column;

  /// Inclusive lower bound.
  final TValue lower;

  /// Inclusive upper bound.
  final TValue upper;

  /// Whether this is a `NOT BETWEEN` test.
  final bool negated;

  @override
  void writeTo(SqlWriter writer) {
    writer.writeIdentifier(column.name);
    writer.write(negated ? ' NOT BETWEEN ' : ' BETWEEN ');
    writer.bindTyped(column.sqlType, column.encodeValue(lower));
    writer.write(' AND ');
    writer.bindTyped(column.sqlType, column.encodeValue(upper));
  }
}

/// `column [NOT] LIKE pattern` or its case-insensitive `ILIKE` variant.
final class ColumnLike<TModel> extends SqlPredicate<TModel> {
  /// Matches [column] against [pattern].
  ///
  /// [pattern] is used verbatim, so `%` and `_` act as wildcards. Prefer the
  /// `ModelColumn` text helpers (`startsWith`, `containsText`, ...) when the
  /// input is literal text that must not be treated as a pattern.
  const ColumnLike(
    this.column,
    this.pattern, {
    this.caseInsensitive = false,
    this.negated = false,
  });

  /// The column being tested.
  final ColumnDefinition column;

  /// The `LIKE` pattern.
  final String pattern;

  /// Whether to use case-insensitive `ILIKE`.
  final bool caseInsensitive;

  /// Whether this is a `NOT LIKE` test.
  final bool negated;

  @override
  void writeTo(SqlWriter writer) => writer.dialect.strategy.writeLike(
    writer,
    column,
    pattern,
    caseInsensitive: caseInsensitive,
    negated: negated,
  );
}

/// A predicate written as raw SQL with `?` value markers.
///
/// ```dart
/// RawSqlPredicate<User>(r"lower(email) = lower(?)", <Object?>[email]);
/// ```
///
/// Executable `?` markers bind values in order; quoted strings/identifiers and
/// comments are preserved. PostgreSQL dollar quotes and ?|/?&/@? are recognized.
/// Write ?? for a literal question mark (including PostgreSQL's lone ? operator).
/// This lexer does not validate SQL syntax; unterminated contexts remain server errors.
final class RawSqlPredicate<TModel> extends SqlPredicate<TModel> {
  /// Creates a predicate from [sql] and its positional [parameters].
  const RawSqlPredicate(this.sql, [this.parameters = const <Object?>[]]);

  /// The SQL fragment, with `?` markers for values; rendering adds parentheses.
  final String sql;

  /// Values bound to the `?` markers, in order.
  final List<Object?> parameters;

  @override
  void writeTo(SqlWriter writer) {
    final parts = splitSqlPlaceholders(sql, writer.dialect);
    if (parts.length - 1 != parameters.length) {
      throw TikalParameterException(
        'Raw predicate has ${parts.length - 1} "?" marker(s) but '
        '${parameters.length} parameter(s).',
      );
    }
    writer.write('(');
    for (var i = 0; i < parts.length; i++) {
      writer.write(parts[i]);
      if (i < parameters.length) writer.bind(parameters[i]);
    }
    writer.write(')');
  }
}

/// `left AND right`.
final class AndPredicate<TModel> extends SqlPredicate<TModel> {
  /// Combines [left] and [right] with `AND`.
  const AndPredicate(this.left, this.right);

  /// Left hand side.
  final SqlPredicate<TModel> left;

  /// Right hand side.
  final SqlPredicate<TModel> right;

  @override
  void writeTo(SqlWriter writer) => _writeBinary(writer, left, ' AND ', right);
}

/// `left OR right`.
final class OrPredicate<TModel> extends SqlPredicate<TModel> {
  /// Combines [left] and [right] with `OR`.
  const OrPredicate(this.left, this.right);

  /// Left hand side.
  final SqlPredicate<TModel> left;

  /// Right hand side.
  final SqlPredicate<TModel> right;

  @override
  void writeTo(SqlWriter writer) => _writeBinary(writer, left, ' OR ', right);
}

/// `NOT predicate`.
final class NotPredicate<TModel> extends SqlPredicate<TModel> {
  /// Negates [predicate].
  const NotPredicate(this.predicate);

  /// The predicate being negated.
  final SqlPredicate<TModel> predicate;

  @override
  void writeTo(SqlWriter writer) {
    writer.write('(NOT ');
    predicate.writeTo(writer);
    writer.write(')');
  }
}

/// Escapes the characters that are special in a `LIKE` pattern.
///
/// Backslash, `%` and `_` become literals when the pattern is used together
/// with `ESCAPE '\'`, which every [ColumnLike] predicate emits.
String escapeLikePattern(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

void _writeBinary<T>(
  SqlWriter writer,
  SqlPredicate<T> left,
  String operator,
  SqlPredicate<T> right,
) {
  writer.write('(');
  left.writeTo(writer);
  writer.write(operator);
  right.writeTo(writer);
  writer.write(')');
}
