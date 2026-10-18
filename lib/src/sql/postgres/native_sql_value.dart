/// PostgreSQL native binding choices, independent of any driver API.
enum PostgresValueType {
  /// Text cast to the server inet type.
  inet,

  /// Native text array.
  textArray,

  /// Native 32-bit integer array.
  integerArray,
}

/// Explicit opt-in PostgreSQL value understood only by its binding adapter.
/// Other engines reject it with TikalUnsupportedException; no fallback changes
/// native semantics. Converters copy array values before constructing this value.
final class NativeSqlValue {
  /// Wraps an already encoded native value.
  const NativeSqlValue(this.type, this.value);

  /// Native PostgreSQL wire representation.
  final PostgresValueType type;

  /// Encoded text or immutable scalar array.
  final Object? value;

  @override
  bool operator ==(Object other) {
    if (other is! NativeSqlValue || type != other.type) return false;
    final left = value;
    final right = other.value;
    return left is List && right is List
        ? left.length == right.length &&
              left.indexed.every((e) => e.$2 == right[e.$1])
        : left == right;
  }

  @override
  int get hashCode =>
      Object.hash(type, value is List ? Object.hashAll(value as List) : value);
}
