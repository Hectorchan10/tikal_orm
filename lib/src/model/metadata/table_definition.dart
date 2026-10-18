import 'package:meta/meta.dart';

// Model
import 'model_column.dart';

// Model
import '../model_state.dart';

// Model
import 'column_definition.dart';

// SQL
import '../../sql/sql_type.dart';

// Query
import '../../query/sql/quoting.dart';

// Database
import '../../database/query_result.dart';

// Query
import '../../query/dialects/dialect.dart';

// Database
import '../../database/query_executor.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Query
import '../../query/expressions/sql_predicate.dart';

/// Table metadata, typed bindings, construction and encoded snapshot policy.
final class TableDefinition<TModel extends Object> {
  final _validatedDialects = <SqlDialect>{};

  /// Validates binding capabilities before any connection is opened or SQL runs.
  /// Throws [TikalUnsupportedException] naming the table, column and engine.
  /// Successful validation is cached on this definition for each dialect;
  /// failed validation is retried. No models or executors are retained by the cache.
  void validateDialect(SqlDialect dialect) {
    if (_validatedDialects.contains(dialect)) return;
    final version = versionColumn;
    if (version != null &&
        (!columns.contains(version) ||
            version.nullable ||
            version.primaryKey ||
            version.encode != null ||
            !{SqlType.integer, SqlType.bigInteger}.contains(version.sqlType))) {
      throw TikalModelException(
        'Version requires a non-null, unconverted integer column.',
      );
    }
    for (final column in columns) {
      if (!dialect.strategy.supports(column.sqlType)) {
        throw TikalUnsupportedException(
          'Table "$name", column "${column.name}": ${column.sqlType.sqlName} is unsupported on ${dialect.name}.',
        );
      }
    }
    _validatedDialects.add(dialect);
  }

  /// Concrete model type used by an explicitly configured registry.
  Type get modelType => TModel;

  /// Creates a table definition.
  TableDefinition({
    required this.name,
    required List<ColumnDefinition> columns,
    TModel Function()? newInstance,
    this.fromRowFactory,
    ModelState<TModel>? state,
    this.schema,
    this.create,
    this.createdAtColumn,
    this.updatedAtColumn,
    this.deletedAtColumn,
    this.versionColumn,
  }) : columns = List.unmodifiable(columns),
       state = state ?? ModelState<TModel>(),
       assert(
         newInstance != null || fromRowFactory != null,
         'Provide newInstance or fromRowFactory.',
       ),
       // ignore: prefer_initializing_formals
       _newInstance = newInstance;

  /// Change tracking for ordinary Dart entities; generated mappings provide it.
  final ModelState<TModel> state;

  /// Returns the optional lifecycle hooks implemented by this model.
  ModelLifecycle? lifecycleFor(TModel model) =>
      model is ModelLifecycle ? model : null;

  /// Whether this model has a persisted snapshot in this mapping.
  bool isPersisted(TModel model) => state.originalValues(model) != null;

  /// Returns names differing from the encoded, structurally compared snapshot.
  Set<String> changedColumnNames(TModel model) {
    final original = state.originalValues(model);
    return {
      for (final entry in encodedValues(model).entries)
        if (original == null ||
            !snapshotEquals(original[entry.key], entry.value))
          entry.key,
    };
  }

  /// Records a deep immutable snapshot of already encoded SQL values.
  void syncOriginal(TModel model) => state.sync(model, encodedValues(model));

  /// Clears the snapshot so save inserts this model again.
  void resetChanges(TModel model) => state.reset(model);

  /// Table name as it appears in the database, without quotes.
  final String name;

  /// Optional namespace: a PostgreSQL schema or MySQL database, ignored on SQLite.
  /// Null uses the engine's current namespace; the generated public default is omitted on MySQL.
  final String? schema;

  /// Immutable columns in declaration order, copied from the constructor input.
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

  /// Optional positive integer counter for optimistic updates and model deletion.
  /// Bulk updates/upserts and bulk soft deletes/restores reject versioned tables.
  final ColumnDefinition? versionColumn;

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
    final model = fromRowUntracked(row);
    syncOriginal(model);
    return model;
  }

  /// Decodes a pending bulk result without publishing a persisted snapshot.
  @internal
  TModel fromRowUntracked(TikalRow row) {
    final model = fromRowFactory?.call(row) ?? newInstance();
    for (final binding in _bindings) {
      binding.writeTo(model, binding.decodeFrom(row));
    }
    return model;
  }

  /// Publishes already decoded bulk values after the transaction succeeds.
  @internal
  void copyValues(TModel source, TModel target) {
    for (final binding in _bindings) {
      binding.writeTo(target, binding.readFrom(source));
    }
  }

  /// Reads every column of [model] into a name to value map.
  ///
  /// Columns map to their Dart values exactly as stored; `null` means the field
  /// is unset.
  Map<String, Object?> readValues(TModel model) => <String, Object?>{
    for (final binding in _bindings)
      binding.definition.name: binding.readFrom(model),
  };

  /// Encodes a column once, normalizing timestamp DateTimes before conversion.
  @internal
  Object? encodeWriteValue(ColumnDefinition column, Object? value) {
    final timestamp =
        column.name == createdAtColumn?.name ||
        column.name == updatedAtColumn?.name ||
        column.name == deletedAtColumn?.name;
    return column.encodeValue(
      timestamp && value is DateTime ? value.toUtc() : value,
    );
  }

  /// Reads SQL-encoded values for immutable snapshots and dirty comparison.
  /// Value objects need no equality override; converters must be deterministic.
  Map<String, Object?> encodedValues(TModel model) => {
    for (final binding in _bindings)
      binding.definition.name: encodeWriteValue(
        binding.definition,
        binding.readFrom(model),
      ),
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

  /// Rejects an incompatible Dart key before encoding or executing SQL.
  /// Keys remain Object to support converted keys without a second model generic.
  /// Throws [TikalModelException] with table, column and received Dart type.
  void validateKeyValue(ColumnDefinition column, Object? value) {
    if (!bindingFor(column).acceptsValue(value)) {
      throw TikalModelException(
        'Invalid key for table "$name", column "${column.name}": '
        'received ${value.runtimeType}; supply the column’s Dart value type.',
      );
    }
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
  /// formed. Application rules added through `ModelLifecycle.validate` are checked
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
