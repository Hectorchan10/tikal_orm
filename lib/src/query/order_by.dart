// Query
import 'dialect.dart';
import 'sql_writer.dart';

// Model
import '../model/column_definition.dart';

/// Whether `NULL` values sort before or after the other values.
enum NullsOrder {
  /// `NULLS FIRST` — nulls come before non-null values for ascending order.
  first,

  /// `NULLS LAST` — nulls come after non-null values for ascending order.
  last,
}

/// A single `ORDER BY` term.
///
/// Instances are created through `ModelColumn.asc()` / `ModelColumn.desc()`:
///
/// ```dart
/// final users = await repository.find(
///   orderBy: <OrderBy<User>>[User_.name.asc(), User_.createdAt.desc()],
/// );
/// ```
final class OrderBy<TModel> {
  /// Orders by [column], ascending unless [descending] is set.
  const OrderBy(this.column, {this.descending = false, this.nulls});

  /// Orders by [column] ascending.
  const OrderBy.asc(this.column, {this.nulls}) : descending = false;

  /// Orders by [column] descending.
  const OrderBy.desc(this.column, {this.nulls}) : descending = true;

  /// The column to sort by.
  final ColumnDefinition column;

  /// Whether the order is descending (`DESC`) instead of ascending (`ASC`).
  final bool descending;

  /// Where `NULL` values are placed, or `null` to use the engine default.
  final NullsOrder? nulls;

  /// Writes this term into [writer].
  void writeTo(SqlWriter writer) => writer.dialect.strategy.writeOrderTerm(
    writer,
    column.name,
    descending: descending,
    nulls: nulls,
  );

  @override
  String toString() =>
      'OrderBy(${column.name}${descending ? ' DESC' : ' ASC'}'
      '${nulls == null ? '' : ', ${nulls!.name}'})';
}
