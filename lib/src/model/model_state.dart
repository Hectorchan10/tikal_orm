import 'dart:async';

import 'package:meta/meta.dart';

/// Optional lifecycle behavior for annotated Dart entities.
/// Add `with ModelLifecycle` only when hooks or application validation are needed.
mixin ModelLifecycle {
  /// Runs before an individual insert; bulk insertion does not invoke this hook.
  FutureOr<void> beforeInsert() {}

  /// Runs after an individual insert has refreshed the persisted model.
  FutureOr<void> afterInsert() {}

  /// Runs before an effective individual update; no-op saves skip this hook.
  FutureOr<void> beforeUpdate() {}

  /// Runs after an individual update has refreshed the persisted model.
  FutureOr<void> afterUpdate() {}

  /// Runs before an individual soft or permanent deletion.
  FutureOr<void> beforeDelete() {}

  /// Runs after an individual deletion affects a row.
  FutureOr<void> afterDelete() {}

  /// Returns application validation errors; an empty list accepts the model.
  List<String> validate() => const [];
}

/// Weak, identity-based change snapshots scoped to a single table definition.
/// Entities are not retained by this state once application references disappear.
final class ModelState<T extends Object> {
  final Expando<Map<String, Object?>> _snapshots = Expando();

  /// Returns the last immutable snapshot, or null for a never-persisted model.
  Map<String, Object?>? originalValues(T model) => _snapshots[model];

  /// Stores a deep, immutable snapshot of already encoded SQL values.
  /// TableDefinition encodes fields before calling this method.
  void sync(T model, Map<String, Object?> values) =>
      _snapshots[model] = snapshotValues(values);

  /// Forgets the snapshot so this model is treated as new and fully dirty.
  void reset(T model) => _snapshots[model] = null;
}

/// Copies mutable JSON collections into an immutable snapshot.
@internal
Map<String, Object?> snapshotValues(Map<String, Object?> values) =>
    Map<String, Object?>.unmodifiable(
      values.map((key, value) => MapEntry(key, _copy(value))),
    );

Object? _copy(Object? value) => switch (value) {
  Map<String, Object?>() => snapshotValues(value),
  Map() => Map<Object?, Object?>.unmodifiable(
    value.map((key, value) => MapEntry(key, _copy(value))),
  ),
  List() => List<Object?>.unmodifiable(value.map(_copy)),
  _ => value,
};

/// Compares scalar values and nested JSON collections structurally.
@internal
bool snapshotEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.entries.every(
          (entry) =>
              right.containsKey(entry.key) &&
              snapshotEquals(entry.value, right[entry.key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        left.indexed.every(
          (entry) => snapshotEquals(entry.$2, right[entry.$1]),
        );
  }
  return left == right;
}
