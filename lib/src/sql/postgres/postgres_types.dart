import 'dart:io';

// SQL
import '../sql_type.dart';
import 'native_sql_value.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Model
import '../../model/conversion/type_converter.dart';

/// Stores textual IPv4/IPv6 addresses (optionally with CIDR prefix) as inet.
/// Pair with DbType(postgres: 'inet'); other engines reject its native binding.
final class InetConverter
    implements TypeConverter<String, Object>, NullEncodingConverter {
  /// Creates a stateless address converter.
  const InetConverter();
  @override
  NativeSqlValue encodeNull() =>
      const NativeSqlValue(PostgresValueType.inet, null);
  @override
  SqlType get sqlType => SqlType.text;
  @override
  NativeSqlValue toDb(String value) {
    _validateInet(value);
    return NativeSqlValue(PostgresValueType.inet, value);
  }

  @override
  String fromDb(Object value) {
    final text = value is InternetAddress ? value.address : value as String;
    _validateInet(text);
    return text;
  }
}

void _validateInet(String value) {
  final parts = value.split('/');
  final address = InternetAddress.tryParse(parts.first);
  final prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
  if (address == null ||
      parts.length > 2 ||
      parts.length == 2 &&
          (prefix == null ||
              prefix < 0 ||
              prefix > (address.type == InternetAddressType.IPv4 ? 32 : 128))) {
    throw TikalColumnException('Invalid inet address: $value.');
  }
}

/// Stores a Dart string list using PostgreSQL's native text-array binding.
final class PostgresTextArrayConverter
    implements TypeConverter<List<String>, Object>, NullEncodingConverter {
  /// Creates a stateless text-array converter.
  const PostgresTextArrayConverter();
  @override
  NativeSqlValue encodeNull() =>
      const NativeSqlValue(PostgresValueType.textArray, null);
  @override
  SqlType get sqlType => SqlType.jsonb;
  @override
  NativeSqlValue toDb(List<String> value) => NativeSqlValue(
    PostgresValueType.textArray,
    List<String>.unmodifiable(value),
  );
  @override
  List<String> fromDb(Object value) => (value as List).cast<String>().toList();
}

/// Stores a Dart integer list using PostgreSQL's native int4-array binding.
final class PostgresIntArrayConverter
    implements TypeConverter<List<int>, Object>, NullEncodingConverter {
  /// Creates a stateless integer-array converter.
  const PostgresIntArrayConverter();
  @override
  NativeSqlValue encodeNull() =>
      const NativeSqlValue(PostgresValueType.integerArray, null);
  @override
  SqlType get sqlType => SqlType.jsonb;
  @override
  NativeSqlValue toDb(List<int> value) => NativeSqlValue(
    PostgresValueType.integerArray,
    List<int>.unmodifiable(value),
  );
  @override
  List<int> fromDb(Object value) => (value as List).cast<int>().toList();
}
