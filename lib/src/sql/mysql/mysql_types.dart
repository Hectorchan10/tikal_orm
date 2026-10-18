// SQL
import '../sql_type.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Model
import '../../model/conversion/type_converter.dart';

/// Stores a year as an integer; pair with DbType(mysql: 'YEAR') for native DDL.
final class MysqlYearConverter implements TypeConverter<int, int> {
  /// Creates a stateless MySQL year converter.
  const MysqlYearConverter();
  @override
  SqlType get sqlType => SqlType.integer;
  @override
  int toDb(int value) => _validate(value);
  @override
  int fromDb(int value) => _validate(value);
  int _validate(int value) {
    if (value == 0 || value >= 1901 && value <= 2155) return value;
    throw TikalColumnException(
      'MySQL YEAR requires zero or a year from 1901 to 2155.',
    );
  }
}

/// Stores a string set as comma-delimited text, compatible with native MySQL SET.
/// Pair with a matching DbType(mysql: "SET('a','b')") declaration. Native SET
/// declaration order can affect readback order; callers should treat it as a set.
final class MysqlSetConverter implements TypeConverter<Set<String>, String> {
  /// Creates a converter with an optional list of allowed SET members.
  const MysqlSetConverter({this.values = const []});

  /// Optional allowed members, in database declaration order.
  final List<String> values;
  @override
  SqlType get sqlType => SqlType.text;
  @override
  String toDb(Set<String> value) {
    for (final member in value) {
      if (member.isEmpty ||
          member.contains(',') ||
          values.isNotEmpty && !values.contains(member)) {
        throw TikalColumnException(
          'Invalid SET member "$member". Valid values: $values.',
        );
      }
    }
    final ordered = values.isEmpty
        ? (value.toList()..sort())
        : values.where(value.contains).toList();
    return ordered.join(',');
  }

  @override
  Set<String> fromDb(String value) {
    final members = value.isEmpty ? <String>{} : value.split(',').toSet();
    toDb(members);
    return members;
  }
}
