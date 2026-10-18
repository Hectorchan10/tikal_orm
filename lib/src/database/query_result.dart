// Errors
import '../errors/tikal_exceptions.dart';

/// A single row returned by the database.
///
/// Values are exposed both positionally and by column name:
///
/// ```dart
/// final row = result.first;
/// print(row['email']);          // Object?
/// print(row.asString('email')); // String?
/// ```
final class TikalRow {
  /// Creates a row from its column names and decoded values.
  TikalRow({required List<String> columnNames, required List<Object?> values})
    : columnNames = List<String>.unmodifiable(columnNames),
      values = List<Object?>.unmodifiable(values);

  /// Column names, in the order the database returned them.
  final List<String> columnNames;

  /// Decoded values, aligned with [columnNames].
  final List<Object?> values;

  /// Number of columns in this row.
  int get length => values.length;

  /// The column names of this row.
  Iterable<String> get columns => columnNames;

  /// Whether this row contains a column called [column].
  bool hasColumn(String column) => columnNames.contains(column);

  /// The position of [column], or throws [TikalColumnException].
  int indexOf(String column) {
    final index = columnNames.indexOf(column);
    if (index < 0) {
      throw TikalColumnException(
        'Column "$column" is not present in this row.',
        column: column,
        available: columnNames,
      );
    }
    return index;
  }

  /// The value of [column], or throws [TikalColumnException] when missing.
  Object? operator [](String column) => values[indexOf(column)];

  /// The value at [index], or throws [TikalColumnException] when out of range.
  Object? valueAt(int index) {
    if (index < 0 || index >= values.length) {
      throw TikalColumnException(
        'Column index $index is out of range; this row has ${values.length} column(s).',
      );
    }
    return values[index];
  }

  /// Whether [column] holds SQL `NULL`.
  bool isNull(String column) => this[column] == null;

  /// Reads [column] as [T], returning `null` for SQL `NULL`.
  ///
  /// Throws [TikalColumnException] when the driver decoded the value into a
  /// different Dart type (for instance `numeric` columns arrive as [String]).
  T? as<T>(String column) {
    final value = this[column];
    if (value == null) return null;
    if (value is! T) {
      throw TikalColumnException(
        'Column "$column" holds a ${value.runtimeType}, which cannot be read as $T.',
        column: column,
        available: columnNames,
      );
    }
    return value as T;
  }

  /// Reads [column] as [String].
  String? asString(String column) => as<String>(column);

  /// Reads [column] as [int].
  int? asInt(String column) => as<int>(column);

  /// Reads [column] as [bool].
  bool? asBool(String column) => as<bool>(column);

  /// Reads [column] as [double].
  double? asDouble(String column) => as<double>(column);

  /// Reads [column] as [DateTime].
  DateTime? asDateTime(String column) => as<DateTime>(column);

  /// Reads [column] as raw bytes.
  List<int>? asBytes(String column) => as<List<int>>(column);

  /// Reads a `json` / `jsonb` column as an object.
  ///
  /// JSON values are decoded into Dart collections, so `json` / `jsonb`
  /// objects arrive as maps and arrays as lists.
  Map<String, Object?>? asMap(String column) =>
      as<Map<String, Object?>>(column);

  /// Reads a `json` / `jsonb` column as an array.
  List<Object?>? asList(String column) => as<List<Object?>>(column);

  /// Reads [column] as a number, accepting values decoded as [String].
  ///
  /// `numeric` / `decimal` columns always arrive as [String] to
  /// preserve precision; this helper parses them into a [num].
  num? asNum(String column) {
    final value = this[column];
    return switch (value) {
      null => null,
      final num value => value,
      final String value =>
        num.tryParse(value) ??
            (throw TikalColumnException(
              'Column "$column" holds "$value", which is not a number.',
              column: column,
            )),
      _ => throw TikalColumnException(
        'Column "$column" holds a ${value.runtimeType}, which cannot be read as num.',
        column: column,
        available: columnNames,
      ),
    };
  }

  /// The row as a name to value map.
  Map<String, Object?> toColumnMap() => <String, Object?>{
    for (final (index, name) in columnNames.indexed) name: values[index],
  };

  @override
  String toString() => 'TikalRow(${toColumnMap()})';
}

/// The outcome of a statement.
///
/// `SELECT` statements fill [rows]; `INSERT` / `UPDATE` / `DELETE` fill
/// [affectedRows] (and [rows] as well when they use `RETURNING`).
final class QueryResult {
  /// Creates a result from already decoded rows.
  const QueryResult({
    required this.rows,
    this.affectedRows = 0,
    this.lastInsertId,
  });

  /// An empty result.
  const QueryResult.empty() : this(rows: const <TikalRow>[]);

  /// Rows returned by the statement.
  final List<TikalRow> rows;

  /// Number of rows inserted, updated or deleted by the statement.
  final int affectedRows;

  /// The last inserted identifier, if available (used by MySQL).
  final int? lastInsertId;

  /// Number of rows in this result.
  int get length => rows.length;

  /// Whether no rows were returned.
  bool get isEmpty => rows.isEmpty;

  /// Whether at least one row was returned.
  bool get isNotEmpty => rows.isNotEmpty;

  /// The first row, or throws [StateError] when there are none.
  TikalRow get first {
    if (rows.isEmpty) {
      throw StateError('The result contains no rows.');
    }
    return rows.first;
  }

  /// The first row, or `null` when there are none.
  TikalRow? get firstOrNull => rows.isEmpty ? null : rows.first;

  /// The only row, or throws [StateError] when the count is not exactly one.
  TikalRow get single {
    if (rows.length != 1) {
      throw StateError('Expected exactly one row, got ${rows.length}.');
    }
    return rows.single;
  }

  /// Maps every row into a value of type [T].
  List<T> map<T>(T Function(TikalRow row) convert) =>
      rows.map(convert).toList();

  /// The rows as name to value maps.
  List<Map<String, Object?>> toColumnMaps() => map((row) => row.toColumnMap());

  @override
  String toString() =>
      'QueryResult(rows: ${rows.length}, affectedRows: $affectedRows, '
      'lastInsertId: $lastInsertId)';
}
