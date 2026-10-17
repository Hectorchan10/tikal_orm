// Model
import 'model_state.dart';
import 'tikal_model.dart';

/// Snapshot policy, independent of how an entity stores its state.
abstract interface class ChangeTracker<T extends Object> {
  bool get isPersisted;
  Set<String> changedColumnNames(Map<String, Object?> Function() values);
  void syncOriginal(Map<String, Object?> Function() values);
  void resetChanges();
}

final class TikalModelTracker<T extends Object> implements ChangeTracker<T> {
  const TikalModelTracker(this.model);
  final TikalModel model;
  @override
  bool get isPersisted => model.isPersisted;
  @override
  Set<String> changedColumnNames(Map<String, Object?> Function() values) =>
      model.changedColumnNames();
  @override
  void syncOriginal(Map<String, Object?> Function() values) =>
      model.syncOriginal();
  @override
  void resetChanges() => model.resetChanges();
}

final class ModelStateTracker<T extends Object> implements ChangeTracker<T> {
  const ModelStateTracker(this.model, this.state);
  final T model;
  final ModelState<T> state;
  @override
  bool get isPersisted => state.originalValues(model) != null;
  @override
  Set<String> changedColumnNames(Map<String, Object?> Function() values) {
    final original = state.originalValues(model);
    return {
      for (final entry in values().entries)
        if (original == null || original[entry.key] != entry.value) entry.key,
    };
  }

  @override
  void syncOriginal(Map<String, Object?> Function() values) =>
      state.sync(model, values());
  @override
  void resetChanges() => state.reset(model);
}
