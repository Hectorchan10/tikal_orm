// Model
import 'model_state.dart';
import 'table_definition.dart';

// Executor
import '../executor/query_result.dart';

/// Optional legacy entity with instance snapshots and lifecycle hooks.
/// Plain annotated classes use the same repositories with ModelState instead.
/// Changes compare current values to the last loaded/written snapshot; SQL
/// rollback does not rewind that snapshot. See README for application examples.
abstract class TikalModel<T extends TikalModel<T>> with ModelLifecycle {
  /// Binds this model to [definition].
  TikalModel(this.definition);

  /// Metadata for the table this model maps to.
  final TableDefinition<T> definition;

  /// This instance typed as the concrete model.
  T get self => this as T;

  Map<String, Object?>? _originalValues;

  /// The values this model had when it was last loaded or written, or `null`
  /// when it was never persisted.
  Map<String, Object?>? get originalValues => _originalValues;

  /// Whether this model was loaded from, or written to, the database.
  ///
  /// A model without a snapshot is treated as fully dirty by
  /// [changedColumnNames].
  bool get isPersisted => _originalValues != null;

  /// Whether any column differs from the last persisted snapshot.
  bool get isDirty => changedColumnNames().isNotEmpty;

  /// The names of the columns whose current value differs from the snapshot.
  ///
  /// A model that was never persisted reports every column as changed. Values
  /// are compared with `==`; reassign a collection (map, list) after mutating it
  /// so the change is detected.
  Set<String> changedColumnNames() {
    final original = _originalValues;
    final current = original == null
        ? const <String, Object?>{}
        : definition.readValues(self);
    return <String>{
      for (final column in definition.columns)
        if (original == null || current[column.name] != original[column.name])
          column.name,
    };
  }

  /// Records the current values as the clean snapshot.
  ///
  /// Called automatically when a model is loaded from a row or written by the
  /// repository; call it manually only after changing a model behind TikalORM's
  /// back.
  void syncOriginal() => _originalValues = definition.readValues(self);

  /// Forgets the snapshot, so every column is considered changed again.
  void resetChanges() => _originalValues = null;

  /// This model as a column name to value map.
  Map<String, Object?> toColumnValues() => definition.readValues(self);

  /// Copies the values of [row] into this model.
  void loadFromRow(TikalRow row) => definition.loadInto(self, row);

  /// The primary key of this model as a column name to value map.
  Map<String, Object?> primaryKeyValues() => definition.primaryKeyValues(self);
}
