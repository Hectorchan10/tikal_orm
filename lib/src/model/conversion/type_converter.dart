// SQL
import '../../sql/sql_type.dart';

/// Converts a Dart value into a supported SQL representation and back.
/// Converters must be deterministic. Null bypasses conversion, and snapshots
/// compare encoded values, so domain objects do not need an equality override.
abstract interface class TypeConverter<D, S> {
  /// The binding type of the encoded value, independent of native DDL overrides.
  SqlType get sqlType;

  /// Encodes a non-null Dart value for storage or comparison.
  S toDb(D value);

  /// Decodes a non-null, normalized SQL value into a Dart value.
  D fromDb(S value);
}

/// Optional explicit typed NULL encoding for native SQL converters.
/// Ordinary converters bypass null. Native adapters can preserve wire type
/// information for null without invoking the converter's non-null toDb method.
abstract interface class NullEncodingConverter {
  /// Returns a typed native NULL marker without converting a domain value.
  Object? encodeNull();
}
