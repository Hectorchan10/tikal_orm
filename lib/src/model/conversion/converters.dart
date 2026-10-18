// Model
import 'type_converter.dart';

// SQL
import '../../sql/sql_type.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

/// Stores durations as a portable signed count of microseconds.
final class DurationMicrosConverter implements TypeConverter<Duration, int> {
  /// Creates a stateless duration converter.
  const DurationMicrosConverter();
  @override
  SqlType get sqlType => SqlType.bigInteger;
  @override
  int toDb(Duration value) => value.inMicroseconds;
  @override
  Duration fromDb(int value) => Duration(microseconds: value);
}

/// Stores a URI in its textual representation.
final class UriConverter implements TypeConverter<Uri, String> {
  /// Creates a stateless URI converter.
  const UriConverter();
  @override
  SqlType get sqlType => SqlType.text;
  @override
  String toDb(Uri value) => value.toString();
  @override
  Uri fromDb(String value) => Uri.parse(value);
}

/// Stores arbitrary precision integers as exact decimal strings.
final class BigIntConverter implements TypeConverter<BigInt, String> {
  /// Creates a stateless large-integer converter.
  const BigIntConverter();
  @override
  SqlType get sqlType => SqlType.numeric;
  @override
  String toDb(BigInt value) => value.toString();
  @override
  BigInt fromDb(String value) => BigInt.parse(value);
}

/// Adapts user-defined JSON serialization without reflection.
/// Subclass with a const constructor and implement toJson/fromJson. Choose json
/// or jsonb explicitly; other types are rejected by the const assertion.
abstract class JsonObjectConverter<T>
    implements TypeConverter<T, Map<String, Object?>> {
  /// Creates a converter using jsonb by default, or portable json when requested.
  const JsonObjectConverter({this.sqlType = SqlType.jsonb})
    : assert(sqlType == SqlType.json || sqlType == SqlType.jsonb);
  @override
  final SqlType sqlType;

  /// Serializes the domain value into a JSON object.
  Map<String, Object?> toJson(T value);

  /// Reconstructs the domain value from a JSON object.
  T fromJson(Map<String, Object?> value);
  @override
  Map<String, Object?> toDb(T value) => toJson(value);
  @override
  T fromDb(Map<String, Object?> value) => fromJson(value);
}

/// Stores enum names and validates database values against a static enum list.
final class EnumNameConverter<E extends Enum>
    implements TypeConverter<E, String> {
  /// Creates a converter from the enum's constant values list.
  const EnumNameConverter(this.values);

  /// Valid enum values in declaration order.
  final List<E> values;
  @override
  SqlType get sqlType => SqlType.text;
  @override
  String toDb(E value) => value.name;
  @override
  E fromDb(String value) =>
      values.where((e) => e.name == value).firstOrNull ??
      (throw TikalColumnException(
        'Unknown enum name "$value". Valid values: ${values.map((e) => e.name).join(', ')}.',
      ));
}

/// Stores enum declaration indices; reordering enum values changes stored meaning.
final class EnumOrdinalConverter<E extends Enum>
    implements TypeConverter<E, int> {
  /// Creates a converter from the enum's constant values list.
  const EnumOrdinalConverter(this.values);

  /// Valid enum values in declaration order.
  final List<E> values;
  @override
  SqlType get sqlType => SqlType.integer;
  @override
  int toDb(E value) => value.index;
  @override
  E fromDb(int value) {
    if (value >= 0 && value < values.length) return values[value];
    throw TikalColumnException(
      'Unknown enum ordinal $value. Valid values: ${values.indexed.map((e) => '${e.$1} (${e.$2.name})').join(', ')}.',
    );
  }
}
