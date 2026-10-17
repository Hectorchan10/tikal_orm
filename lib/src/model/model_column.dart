// Query
import '../query/order_by.dart';

// Model
import 'column_definition.dart';

// Config
import '../config/sql_type.dart';

// Query
import '../query/sql_predicate.dart';

// Executor
import '../executor/query_result.dart';

/// Reads a model field into its Dart value.
typedef ColumnGetter<TModel, TValue> = TValue? Function(TModel model);

/// Writes a Dart value back into a model field.
typedef ColumnSetter<TModel, TValue> = void Function(
  TModel model,
  TValue? value,
);

/// Reads a column out of a result row into its Dart value.
typedef ColumnDecoder<TValue> = TValue? Function(TikalRow row);

/// The model-bound view of a column, used by `TableDefinition` when reading a
/// model's values or building one from a row.
///
/// The interface erases the value type so a heterogeneous list of columns can
/// live in one `TableDefinition`. Each concrete `ModelColumn` implements it by
/// delegating to its typed closures, performing the only cast involved — an
/// [Object] down to `TValue` inside [writeTo] — which keeps the design sound.
abstract interface class ModelColumnBinding<TModel> {
  /// The underlying column metadata.
  ColumnDefinition get definition;

  /// Reads this column's value out of [model].
  Object? readFrom(TModel model);

  /// Writes [value] into [model]'s field for this column.
  void writeTo(TModel model, Object? value);

  /// Decodes this column's value out of [row].
  Object? decodeFrom(TikalRow row);
}

/// A typed column that links SQL column metadata to a model field.
///
/// ```dart
/// final class UserColumns {
///   static final id = ModelColumn<User, int>(
///     name: 'id',
///     sqlType: SqlType.integer,
///     read: (user) => user.id,
///     write: (user, value) => user.id = value,
///     primaryKey: true,
///     autoIncrement: true,
///     hasDefault: true,
///   );
/// }
/// ```
///
/// The comparison helpers build parameterised predicates, so
/// `UserColumns.age.greaterThan(18)` renders `"age" > $1` with the value bound
/// using the column's own SQL type:
///
/// ```dart
/// final adults = await users.find(
///   where: UserColumns.age.greaterThanOrEqual(18),
///   orderBy: <OrderBy<User>>[UserColumns.name.asc()],
/// );
/// ```
class ModelColumn<TModel, TValue> extends ColumnDefinition
    implements ModelColumnBinding<TModel> {
  /// Creates a typed column binding.
  ///
  /// [decode] defaults to `row.as<TValue>(name)`. Numeric columns, whose values
  /// arrive as strings, should pass `decodeNum` (from `decoders.dart`) or an
  /// equivalent closure.
  ModelColumn({
    required super.name,
    required super.sqlType,
    required this.read,
    required this.write,
    ColumnDecoder<TValue>? decode,
    super.nullable,
    super.hasDefault,
    super.primaryKey,
    super.unique,
    super.autoIncrement,
    super.comment,
  }) : decode = decode ?? ((row) => row.as<TValue>(name));

  /// Reads the model field for this column.
  final ColumnGetter<TModel, TValue> read;

  /// Writes the model field for this column.
  final ColumnSetter<TModel, TValue> write;

  /// Reads this column out of a result row.
  final ColumnDecoder<TValue> decode;

  @override
  ColumnDefinition get definition => this;

  @override
  Object? readFrom(TModel model) => read(model);

  @override
  void writeTo(TModel model, Object? value) => write(model, value as TValue?);

  @override
  Object? decodeFrom(TikalRow row) => decode(row);

  // ---------------------------------------------------------------------------
  // Comparisons
  // ---------------------------------------------------------------------------

  /// `column = value`, or `column IS NULL` when [value] is `null`.
  SqlPredicate<TModel> equals(TValue? value) => value == null
      ? ColumnNullCheck<TModel>(this, isNull: true)
      : _compare(SqlOperator.equal, value);

  /// `column <> value`, or `column IS NOT NULL` when [value] is `null`.
  SqlPredicate<TModel> notEquals(TValue? value) => value == null
      ? ColumnNullCheck<TModel>(this, isNull: false)
      : _compare(SqlOperator.notEqual, value);

  /// `column > value`.
  SqlPredicate<TModel> greaterThan(TValue value) =>
      _compare(SqlOperator.greaterThan, value);

  /// `column >= value`.
  SqlPredicate<TModel> greaterThanOrEqual(TValue value) =>
      _compare(SqlOperator.greaterThanOrEqual, value);

  /// `column < value`.
  SqlPredicate<TModel> lessThan(TValue value) =>
      _compare(SqlOperator.lessThan, value);

  /// `column <= value`.
  SqlPredicate<TModel> lessThanOrEqual(TValue value) =>
      _compare(SqlOperator.lessThanOrEqual, value);

  SqlPredicate<TModel> _compare(SqlOperator operator, TValue value) =>
      ColumnComparison<TModel, TValue>(this, operator, value);

  /// `column IS NULL`.
  SqlPredicate<TModel> isNull() => ColumnNullCheck<TModel>(this, isNull: true);

  /// `column IS NOT NULL`.
  SqlPredicate<TModel> isNotNull() =>
      ColumnNullCheck<TModel>(this, isNull: false);

  /// `column IN (values...)`.
  SqlPredicate<TModel> isIn(Iterable<TValue> values) =>
      ColumnInList<TModel, TValue>(this, values.toList(growable: false));

  /// `column NOT IN (values...)`.
  SqlPredicate<TModel> isNotIn(Iterable<TValue> values) =>
      ColumnInList<TModel, TValue>(
        this,
        values.toList(growable: false),
        negated: true,
      );

  /// `column BETWEEN lower AND upper`.
  SqlPredicate<TModel> between(TValue lower, TValue upper) =>
      ColumnBetween<TModel, TValue>(this, lower, upper);

  /// `column NOT BETWEEN lower AND upper`.
  SqlPredicate<TModel> notBetween(TValue lower, TValue upper) =>
      ColumnBetween<TModel, TValue>(this, lower, upper, negated: true);

  // ---------------------------------------------------------------------------
  // Ordering
  // ---------------------------------------------------------------------------

  /// Sorts ascending by this column.
  OrderBy<TModel> asc({NullsOrder? nulls}) =>
      OrderBy<TModel>.asc(this, nulls: nulls);

  /// Sorts descending by this column.
  OrderBy<TModel> desc({NullsOrder? nulls}) =>
      OrderBy<TModel>.desc(this, nulls: nulls);
}

/// A `ModelColumn` whose Dart value is a `String`, with the text helpers.
///
/// ```dart
/// final class UserColumns {
///   static final email = TextColumn<User>(
///     name: 'email',
///     read: (user) => user.email,
///     write: (user, value) => user.email = value,
///   );
/// }
///
/// UserColumns.email.containsText('example.com');
/// ```
final class TextColumn<TModel> extends ModelColumn<TModel, String> {
  /// Creates a text column binding. [sqlType] defaults to `text`.
  TextColumn({
    required super.name,
    super.sqlType = SqlType.text,
    required super.read,
    required super.write,
    super.decode,
    super.nullable,
    super.hasDefault,
    super.primaryKey,
    super.unique,
    super.autoIncrement,
    super.comment,
  });

  /// `column LIKE pattern`, matching the whole value.
  ///
  /// [pattern] is used verbatim; `%` and `_` are wildcards.
  SqlPredicate<TModel> like(String pattern) =>
      ColumnLike<TModel>(this, pattern);

  /// `column NOT LIKE pattern`.
  SqlPredicate<TModel> notLike(String pattern) =>
      ColumnLike<TModel>(this, pattern, negated: true);

  /// `column ILIKE pattern`, case-insensitive.
  SqlPredicate<TModel> ilike(String pattern) =>
      ColumnLike<TModel>(this, pattern, caseInsensitive: true);

  /// `column NOT ILIKE pattern`, case-insensitive.
  SqlPredicate<TModel> notIlike(String pattern) =>
      ColumnLike<TModel>(this, pattern, caseInsensitive: true, negated: true);

  /// Matches values that start with [prefix], treating it as literal text.
  SqlPredicate<TModel> startsWith(String prefix) =>
      like('${escapeLikePattern(prefix)}%');

  /// Matches values that end with [suffix], treating it as literal text.
  SqlPredicate<TModel> endsWith(String suffix) =>
      like('%${escapeLikePattern(suffix)}');

  /// Matches values that contain [text], treating it as literal text.
  SqlPredicate<TModel> containsText(String text) =>
      like('%${escapeLikePattern(text)}%');
}
