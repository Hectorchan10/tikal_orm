// Model
import 'model_state.dart';
import 'tikal_model.dart';
import 'model_column.dart';
import 'change_tracker.dart';

// Query
import '../query/dialect.dart';
import '../query/quoting.dart';

// Model
import 'column_definition.dart';

// Query
import '../query/sql_predicate.dart';

// Executor
import '../executor/query_result.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';

/// Table metadata, typed column bindings and model construction/state policy.
final class TableDefinition<TModel extends Object> {
  /// Concrete model type used by an explicitly configured registry.
  Type get modelType => TModel;

  /// Creates a table definition.
  const TableDefinition({
    required this.name,
    required this.columns,
    // Public parameter name preserves existing manual mappings.
    TModel Function()? newInstance,
    this.fromRowFactory,
    this.state,
    this.schema,
    this.create,
    this.createdAtColumn,
    this.updatedAtColumn,
    this.deletedAtColumn,
  }) : assert(
         newInstance != null || fromRowFactory != null,
         'Provide newInstance or fromRowFactory.',
       ),
       // ignore: prefer_initializing_formals
       _newInstance = newInstance;

  /// Change tracking for ordinary Dart entities; generated mappings provide it.
  final ModelState<TModel>? state;

  ModelState<TModel> get _state =>
      state ??
      (throw TikalModelException(
        'Plain model mappings must provide ModelState.',
      ));
  ModelLifecycle? lifecycleFor(TModel model) =>
      model is ModelLifecycle ? model : null;
  ChangeTracker<TModel> _tracker(TModel model) => model is TikalModel
      ? TikalModelTracker<TModel>(model)
      : ModelStateTracker(model, _state);
  bool isPersisted(TModel model) => _tracker(model).isPersisted;
  Set<String> changedColumnNames(TModel model) =>
      _tracker(model).changedColumnNames(() => readValues(model));
  void syncOriginal(TModel model) =>
      _tracker(model).syncOriginal(() => readValues(model));
  void resetChanges(TModel model) => _tracker(model).resetChanges();

  /// Table name as it appears in the database, without quotes.
  final String name;

  /// Optional schema name; when omitted the session's `search_path` applies.
  final String? schema;

  /// The columns of the table, in declaration order.
  final List<ColumnDefinition> columns;

  /// Builds an empty model, used when materialising rows.
  final TModel Function()? _newInstance;

  /// Optional row constructor used by generated mappings for required fields.
  final TModel Function(TikalRow row)? fromRowFactory;

  /// Empty-model factory for manually mapped models.
  TModel Function() get newInstance =>
      _newInstance ??
      (throw TikalModelException(
        'This generated table requires a row; use fromRow.',
      ));

  /// The `CREATE TABLE` statement for this table, used by schema tooling.
  ///
  /// TikalORM never runs this automatically; it is provided so scripts and
  /// tests can create the table.
  final String? create;

  /// Column that stores the creation timestamp, or `null` to opt out.
  ///
  /// When set, `Repository.insert` fills it (and [updatedAtColumn]) on insert
  /// unless the caller already supplied a value.
  final ColumnDefinition? createdAtColumn;

  /// Column that stores the last-modification timestamp, or `null` to opt out.
  ///
  /// When set, `Repository.insert` and every effective `Repository.update`
  /// write the current time into it.
  final ColumnDefinition? updatedAtColumn;

  /// Column that stores the soft-delete timestamp, or `null` when soft deletes
  /// are disabled.
  ///
  /// When set, `Repository.delete` marks the row instead of removing it and
  /// every query excludes rows whose column is not `NULL`, unless it opts in
  /// with `QueryBuilder.withTrashed` / `onlyTrashed`.
  final ColumnDefinition? deletedAtColumn;

  /// Whether this table supports soft deletes.
  bool get softDeletes => deletedAtColumn != null;

  /// [name] quoted for PostgreSQL.
  String get quotedName => quotedIdentifier(name);

  /// [name] quoted for [dialect].
  String quotedNameFor(SqlDialect dialect) => quotedIdentifier(name, dialect);

  /// `[schema].[name]`, both quoted for PostgreSQL, or just the quoted table name.
  String get qualifiedName =>
      schema == null ? quotedName : '${quotedIdentifier(schema!)}.$quotedName';

  /// Like [qualifiedName], but adapted to [dialect].
  ///
  /// SQLite has no schema namespace, so the schema is omitted there. MySQL has
  /// no separate schema namespace either (a "schema" is a database) and the
  /// generated mappings default every table to `public`, so that default is
  /// omitted as well; an explicit non-default schema is kept as
  /// `` `database`.`table` ``. PostgreSQL keeps `"schema"."table"`.
  String qualifiedNameFor(SqlDialect dialect) =>
      dialect.strategy.qualifiedName(name, schema);

  /// The quoted column list, `"id", "email", ...` for PostgreSQL.
  String get quotedColumns =>
      columns.map((c) => quotedIdentifier(c.name)).join(', ');

  /// The column list quoted for [dialect].
  String quotedColumnsFor(SqlDialect dialect) =>
      columns.map((c) => quotedIdentifier(c.name, dialect)).join(', ');

  /// The columns that make up the primary key, in declaration order.
  List<ColumnDefinition> get primaryKeyColumns =>
      columns.where((c) => c.primaryKey).toList(growable: false);

  /// Whether the table has exactly one primary key column.
  bool get hasSinglePrimaryKey => primaryKeyColumns.length == 1;

  /// The single primary key column.
  ///
  /// Throws [TikalModelException] when the table has no primary key or a
  /// composite one, since the keyed helpers (`findById`, `update`, `delete`)
  /// only support a single column.
  ColumnDefinition get singlePrimaryKey {
    final keys = primaryKeyColumns;
    if (keys.length == 1) return keys.single;
    throw TikalModelException(
      keys.isEmpty
          ? 'Table "$name" has no primary key, so this operation is not available. '
                'Mark one column with primaryKey: true.'
          : 'Table "$name" has a composite primary key '
                '(${keys.map((c) => c.name).join(', ')}); this operation only '
                'supports a single-column key.',
    );
  }

  /// Builds a model from [row] using every column's decoder.
  TModel fromRow(TikalRow row) {
    final model = fromRowFactory?.call(row) ?? newInstance();
    loadInto(model, row);
    return model;
  }

  /// Reads every column of [model] into a name to value map.
  ///
  /// Columns map to their Dart values exactly as stored; `null` means the field
  /// is unset.
  Map<String, Object?> readValues(TModel model) => <String, Object?>{
    for (final binding in _bindings)
      binding.definition.name: binding.readFrom(model),
  };

  /// Copies every column of [row] into [model].
  ///
  /// The model's change snapshot is refreshed afterwards, so a freshly loaded
  /// model is clean and only later edits show up as changed columns.
  void loadInto(TModel model, TikalRow row) {
    for (final binding in _bindings) {
      binding.writeTo(model, binding.decodeFrom(row));
    }
    syncOriginal(model);
  }

  /// The column binding for [column], matching by identity or name.
  ///
  /// Throws [TikalModelException] when [column] does not belong to this table.
  ModelColumnBinding<TModel> bindingFor(ColumnDefinition column) {
    for (final binding in _bindings) {
      if (identical(binding.definition, column) ||
          binding.definition.name == column.name) {
        return binding;
      }
    }
    throw TikalModelException(
      'Column "${column.name}" is not part of table "$name".',
    );
  }

  /// Reads [column] out of [model]'s field.
  Object? readColumn(TModel model, ColumnDefinition column) =>
      bindingFor(column).readFrom(model);

  /// Writes [value] into [model]'s field for [column].
  void writeColumn(TModel model, ColumnDefinition column, Object? value) =>
      bindingFor(column).writeTo(model, value);

  /// A `column IS NULL` predicate for the soft-delete column, or `null` when
  /// the table does not support soft deletes.
  SqlPredicate<TModel>? deletedFilter({required bool isNull}) {
    final column = deletedAtColumn;
    if (column == null) return null;
    return ColumnNullCheck<TModel>(column, isNull: isNull);
  }

  /// The primary key of [model] as a name to value map.
  Map<String, Object?> primaryKeyValues(TModel model) {
    final values = readValues(model);
    return <String, Object?>{
      for (final column in primaryKeyColumns) column.name: values[column.name],
    };
  }

  /// Validates [model] against the table's structural rules.
  ///
  /// Returns one message per problem; an empty list means the model is well
  /// formed. Application rules added through `TikalModel.validate` are checked
  /// separately by the repository.
  List<String> validate(TModel model, {required bool forInsert}) {
    final values = readValues(model);
    if (forInsert) {
      return [
        for (final column in columns)
          if (column.required && values[column.name] == null)
            'Column "${column.name}" is required and cannot be null.',
      ];
    }
    return [
      for (final column in columns)
        if (values[column.name] == null)
          if (column.primaryKey)
            'The primary key "${column.name}" must be set to update a row.'
          else if (!column.nullable)
            'Column "${column.name}" cannot be set to null.',
    ];
  }

  Iterable<ModelColumnBinding<TModel>> get _bindings sync* {
    for (final column in columns) {
      if (column is! ModelColumnBinding<TModel>) {
        throw TikalModelException(
          'Column "${column.name}" of table "$name" is not bound to a model of '
          'the expected type. Use ModelColumn or TextColumn for every column of '
          'a table definition.',
        );
      }
      yield column as ModelColumnBinding<TModel>;
    }
  }

  @override
  String toString() =>
      'TableDefinition(${schema == null ? '' : '$schema.'}$name, '
      '${columns.length} columns)';
}
