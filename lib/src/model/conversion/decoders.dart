import 'dart:convert';
import 'dart:typed_data';

// SQL
import '../../sql/sql_type.dart';

// Database
import '../../database/query_result.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

/// Reads [column] from [row] as an `int`.
///
/// PostgreSQL `integer` / `bigint` columns already arrive as [int]; this helper
/// also accepts numeric strings so it can back both `integer` and `numeric`
/// columns.
int? decodeInt(TikalRow row, String column) => _number<int>(
  row,
  column,
  (value) => value.toInt(),
  (value) => int.tryParse(value) ?? double.tryParse(value)?.toInt(),
);

/// Reads [column] from [row] as a [num].
///
/// PostgreSQL `numeric` / `decimal` columns always arrive as [String] to keep
/// their precision; this helper parses them.
num? decodeNum(TikalRow row, String column) =>
    _number<num>(row, column, (value) => value, num.tryParse);

/// Reads [column] from [row] as a `double`.
double? decodeDouble(TikalRow row, String column) =>
    _number<double>(row, column, (value) => value.toDouble(), double.tryParse);

/// Reads [column] from [row] as a `bool`.
///
/// PostgreSQL returns a real [bool]; SQLite stores booleans as `0` / `1`
/// integers, so both are accepted.
bool? decodeBool(TikalRow row, String column) => _convert<bool>(
  row,
  column,
  convert: (value) => switch (value) {
    final int value when value == 0 || value == 1 => value == 1,
    '0' => false,
    '1' => true,
    _ => null,
  },
);

/// Reads [column] from [row] as a `String`.
String? decodeString(TikalRow row, String column) =>
    _convert<String>(row, column);

/// Reads [column] from [row] as a `DateTime`.
DateTime? decodeDateTime(TikalRow row, String column) => _convert<DateTime>(
  row,
  column,
  convert: (value) => switch (value) {
    final String value =>
      DateTime.tryParse(value) ??
          (throw TikalColumnException(
            'Column "$column" holds "$value", which is not a valid timestamp.',
            column: column,
          )),
    _ => null,
  },
);

/// Reads [column] from [row] as raw bytes.
Uint8List? decodeBytes(TikalRow row, String column) => _convert<Uint8List>(
  row,
  column,
  convert: (value) => value is List<int> ? Uint8List.fromList(value) : null,
);

/// Reads [column] from [row] as a number, preserving `numeric` precision.
///
/// PostgreSQL returns `numeric` / `decimal` as [String]; SQLite may return
/// [String] or [num] depending on the column's affinity. Both are normalised to
/// a [String] so callers keep arbitrary precision.
String? decodeDecimal(TikalRow row, String column) => _convert<String>(
  row,
  column,
  convert: (value) => value is num ? value.toString() : null,
  expected: 'decimal String',
);

/// Reads any JSON scalar, object or array, decoding portable text representations.
/// Throws [TikalColumnException] for malformed JSON.
Object? decodeJson(TikalRow row, String column) =>
    _jsonValue<Object>(row, column);

/// Reads [column] from [row] as a JSON object.
///
/// PostgreSQL decodes `json` / `jsonb` into Dart maps; SQLite stores JSON as
/// text, which is parsed here.
Map<String, Object?>? decodeMap(TikalRow row, String column) =>
    _jsonValue<Map<String, Object?>>(row, column);

/// Reads [column] from [row] as a JSON array.
///
/// PostgreSQL decodes `json` / `jsonb` into Dart lists; SQLite stores JSON as
/// text, which is parsed here.
List<Object?>? decodeList(TikalRow row, String column) =>
    _jsonValue<List<Object?>>(row, column);

T? _jsonValue<T>(TikalRow row, String column) {
  final value = row[column];
  if (value == null) return null;
  final decoded = value is String || value is Uint8List
      ? _decodeJson(value, column)
      : value;
  if (decoded is T) return decoded;
  // Preserve the lazy key cast for maps returned with a wider driver type.
  if (T == (Map<String, Object?>) && decoded is Map<Object?, Object?>) {
    return decoded.cast<String, Object?>() as T;
  }
  throw _wrongType(column, decoded ?? value, '$T', row);
}

Object? _decodeJson(Object value, String column) {
  try {
    return jsonDecode(
      value is Uint8List ? utf8.decode(value) : value as String,
    );
  } on FormatException {
    throw TikalColumnException(
      'Column "$column" holds "$value", which is not valid JSON.',
      column: column,
    );
  }
}

T? _number<T extends num>(
  TikalRow row,
  String column,
  T Function(num) fromNumber,
  T? Function(String) parse,
) => _convert<T>(
  row,
  column,
  convert: (value) => switch (value) {
    num() => fromNumber(value),
    String() => parse(value) ?? (throw _notANumber(column, value, '$T')),
    _ => null,
  },
);

T? _convert<T>(
  TikalRow row,
  String column, {
  T? Function(Object value)? convert,
  String? expected,
}) {
  final value = row[column];
  if (value == null) return null;
  if (value is T) return value as T;
  return convert?.call(value) ??
      (throw _wrongType(column, value, expected ?? '$T', row));
}

TikalColumnException _wrongType(
  String column,
  Object value,
  String expected,
  TikalRow row,
) => TikalColumnException(
  'Column "$column" holds a ${value.runtimeType}, which cannot be read as $expected.',
  column: column,
  available: row.columnNames,
);

TikalColumnException _notANumber(
  String column,
  String value,
  String expected,
) => TikalColumnException(
  'Column "$column" holds "$value", which is not a valid $expected.',
  column: column,
);

/// Normalizes driver values before a converter's fromDb method is called.
/// Throws [TikalColumnException] when the stored value has an incompatible type.
Object? decodeSqlValue(TikalRow row, String column, SqlType type) =>
    switch (type) {
      SqlType.integer ||
      SqlType.smallInteger ||
      SqlType.bigInteger => decodeInt(row, column),
      SqlType.doublePrecision => decodeDouble(row, column),
      SqlType.numeric => decodeDecimal(row, column),
      SqlType.boolean => decodeBool(row, column),
      SqlType.timestamp ||
      SqlType.timestamptz ||
      SqlType.date => decodeDateTime(row, column),
      SqlType.byteArray => decodeBytes(row, column),
      SqlType.json || SqlType.jsonb => _jsonValue<Object>(row, column),
      _ => row[column],
    };
