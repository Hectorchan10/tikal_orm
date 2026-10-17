import 'dart:async';

/// Optional lifecycle behavior for both ordinary Dart entities and TikalModel.
/// Add `with ModelLifecycle` only when hooks or application validation are needed.
mixin ModelLifecycle {
  FutureOr<void> beforeInsert() {}
  FutureOr<void> afterInsert() {}
  FutureOr<void> beforeUpdate() {}
  FutureOr<void> afterUpdate() {}
  FutureOr<void> beforeDelete() {}
  FutureOr<void> afterDelete() {}
  List<String> validate() => const [];
}

/// Weak, identity-based change snapshots scoped to a single table definition.
/// Entities are not retained by this state once application references disappear.
final class ModelState<T extends Object> {
  final Expando<Map<String, Object?>> _snapshots = Expando();
  Map<String, Object?>? originalValues(T model) => _snapshots[model];
  void sync(T model, Map<String, Object?> values) =>
      _snapshots[model] = Map.unmodifiable(values);
  void reset(T model) => _snapshots[model] = null;
}
