// Repository
import 'write_strategy.dart';

// Query
import '../query/dialect.dart';
import '../query/order_by.dart';
import '../query/sql_writer.dart';
import '../query/query_builder.dart';
import '../query/sql_predicate.dart';

// Model
import '../model/table_definition.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';

// Model
import '../model/column_definition.dart';

// Executor
import '../executor/transaction_isolation.dart';

/// Reads and writes models of type [TModel] through a [QueryExecutor].
///
/// The repository is created explicitly, because Dart has no runtime reflection:
/// it needs the [definition] that describes the table.
///
/// Every statement is parameterised; no user value is ever interpolated into
/// the SQL. Predicates bind their values using the column's SQL type, so
/// `uuid`, `numeric`, `date` and other columns compare correctly.
final class Repository<TModel extends Object> {
  /// Creates a repository that runs its statements through [executor].
  ///
  /// [clock] supplies the current time for timestamps and soft deletes and
  /// defaults to [DateTime.now]; pass a fixed function in tests.
  const Repository({
    required this.executor,
    required this.definition,
    this.clock,
  });

  /// The executor statements are sent to.
  ///
  /// This is a `TikalDatabase`, a transaction or a session, so the same
  /// repository code runs inside or outside a transaction. Use
  /// [usingExecutor] to rebind it to a transaction handle.
  final QueryExecutor executor;

  /// Metadata for the table behind [TModel].
  final TableDefinition<TModel> definition;

  /// Source of the current time for `createdAt` / `updatedAt` and soft deletes.
  final DateTime Function()? clock;

  DateTime _now() => (clock ?? DateTime.now)();

  /// Returns a repository bound to [executor], sharing this definition.
  ///
  /// Handy to run several operations on the same transaction:
  ///
  Repository<TModel> usingExecutor(QueryExecutor executor) =>
      Repository<TModel>(
        executor: executor,
        definition: definition,
        clock: clock,
      );

  /// Starts a fluent `SELECT` for this model with no clauses yet.
  ///
  QueryBuilder<TModel> query() =>
      QueryBuilder<TModel>(executor: executor, definition: definition);

  /// Starts a fluent `SELECT` filtered by [predicate].
  ///
  /// This is what makes `User.query(db).where(...)` read as one sentence: the
  /// model's static `query(db)` returns a repository and this hands back a
  /// [QueryBuilder] seeded with the first condition.
  QueryBuilder<TModel> where(SqlPredicate<TModel> predicate) =>
      query().where(predicate);

  /// Starts a fluent query that also returns soft-deleted rows.
  QueryBuilder<TModel> withTrashed() => query().withTrashed();

  /// Starts a fluent query restricted to soft-deleted rows.
  QueryBuilder<TModel> onlyTrashed() => query().onlyTrashed();

  /// Runs [action] in a transaction, handing it a rebound repository.
  ///
  /// When the executor is a `TikalDatabase`, a real transaction is opened and
  /// rolled back if [action] throws. When the repository is already bound to a
  /// transaction or a session, [action] simply runs on it and joins that
  /// transaction.
  Future<T> transaction<T>(
    Future<T> Function(Repository<TModel> tx) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) {
    final current = executor;
    if (current is TransactionExecutor) {
      return (current as TransactionExecutor).transaction<T>(
        (tx) => action(usingExecutor(tx)),
        isolation: isolation,
        readOnly: readOnly,
        timeout: timeout,
      );
    }
    return action(this);
  }

  /// Inserts [model] and returns it, populated from the returned row.
  ///
  /// The write strategy populates server-generated values on [model]. When the
  /// table declares `createdAt` / `updatedAt` columns, both are stamped with the
  /// current time unless already set. Lifecycle hooks ([TikalModel.beforeInsert]
  /// / [TikalModel.afterInsert]) run around the statement.
  Future<TModel> insert(TModel model, {Duration? timeout}) async =>
      _persist(model, timeout, runHooks: true);

  /// Inserts every model in [models]. MySQL uses ordered individual inserts
  /// in a transaction (savepoint when already in one), without lifecycle hooks.
  ///
  /// The column list is the union of the columns that carry a value in at least
  /// one model plus every required column. A model that omits an included
  /// column binds `NULL` for it, which must be allowed by the column (nullable
  /// or defaulted). Rows are returned in the order the database returns them,
  /// which for a single `INSERT ... RETURNING` matches the input order.
  ///
  /// Timestamps are applied to every model, but **lifecycle hooks do not run**
  /// for bulk inserts; use [insert] when a model needs its hooks.
  Future<List<TModel>> insertAll(
    Iterable<TModel> models, {
    Duration? timeout,
  }) async {
    final list = models.toList(growable: false);
    if (list.isEmpty) return [];
    return _writes.insertAll(
      list,
      () => _prepareInsert(list),
      _writeWithoutHooks(timeout),
      timeout,
    );
  }

  WriteStrategy<TModel> get _writes =>
      dialectOf(executor).strategy.supportsReturning
      ? ReturningWriteStrategy(executor, definition)
      : ReloadWriteStrategy(executor, definition);

  SingleWrite<TModel> _writeWithoutHooks(Duration? timeout) =>
      (tx, model, spec) =>
          usingExecutor(tx)
              ._persist(model, timeout, runHooks: false, spec: spec);

  /// Inserts or updates [models] with a single `INSERT ... ON CONFLICT`.
  ///
  /// Conflicting rows are matched on [conflictColumns], which must correspond to
  /// a unique index or the primary key. Matching rows are updated with the
  /// values proposed by the insert, using the `EXCLUDED` pseudo-table,
  /// unless [updateColumns] is empty, in which case conflicts are left alone
  /// (`DO NOTHING`). [updateColumns] defaults to every inserted column that is
  /// neither part of the conflict target nor a primary key.
  ///
  /// Timestamps are applied; like [insertAll], lifecycle hooks do not run.
  /// MySQL uses ON DUPLICATE KEY on any unique index. conflictColumns serves
  /// only to reload each result; a different unique conflict may fail the reload.
  /// MySQL performs individual statements in a transaction/savepoint.
  Future<List<TModel>> upsert(
    Iterable<TModel> models, {
    required List<ColumnDefinition> conflictColumns,
    List<ColumnDefinition>? updateColumns,
    Duration? timeout,
  }) async {
    if (conflictColumns.isEmpty) {
      throw ArgumentError.value(
        conflictColumns,
        'conflictColumns',
        'An upsert needs at least one conflict column.',
      );
    }
    final list = models.toList(growable: false);
    if (list.isEmpty) return <TModel>[];
    final (columns, valueMaps) = _prepareInsert(list);
    if (columns.isEmpty) {
      throw TikalModelException(
        'Upsert into "${definition.name}" needs at least one value column.',
      );
    }

    return _writes.upsert(
      list,
      (columns, valueMaps),
      UpsertSpec(conflictColumns, updateColumns),
      _writeWithoutHooks(timeout),
      timeout,
    );
  }

  /// Inserts or updates a single [model]; see [upsert].
  ///
  /// Returns the stored row. Throws [TikalEntityNotFoundException] when the
  /// conflict was resolved with `DO NOTHING` and no row came back.
  Future<TModel> upsertOne(
    TModel model, {
    required List<ColumnDefinition> conflictColumns,
    List<ColumnDefinition>? updateColumns,
    Duration? timeout,
  }) async {
    final rows = await upsert(
      <TModel>[model],
      conflictColumns: conflictColumns,
      updateColumns: updateColumns,
      timeout: timeout,
    );
    return rows.firstOrNull ??
        (throw TikalEntityNotFoundException(
          table: definition.name,
          primaryKey: definition.primaryKeyValues(model),
        ));
  }

  /// Updates the row that [model]'s primary key identifies.
  ///
  /// When [model] was loaded from the database (or written by a previous save),
  /// only the columns that actually changed are written, so concurrent edits to
  /// other columns are not clobbered; pass `onlyChanged: false` to write every
  /// non-key column. A model with no snapshot (never loaded or saved) writes all
  /// non-key columns. When nothing changed, no statement is sent.
  ///
  /// When the table declares an `updatedAt` column it is stamped with the
  /// current time. Lifecycle hooks ([TikalModel.beforeUpdate] /
  /// [TikalModel.afterUpdate]) run around the statement. When no row matches,
  /// a [TikalEntityNotFoundException] is thrown. The returned model reflects the
  /// row after the update.
  Future<TModel> update(
    TModel model, {
    Duration? timeout,
    bool onlyChanged = true,
  }) async {
    _validate(model, forInsert: false);
    final key = definition.singlePrimaryKey;
    final Set<String>? changed = onlyChanged && definition.isPersisted(model)
        ? definition.changedColumnNames(model)
        : null;
    if (changed != null && changed.isEmpty) {
      return model;
    }

    await definition.lifecycleFor(model)?.beforeUpdate();
    _validate(model, forInsert: false);
    // A hook may change a different column than the caller did.
    changed?.addAll(definition.changedColumnNames(model));
    final updatedAt = definition.updatedAtColumn;
    if (updatedAt != null) {
      definition.writeColumn(model, updatedAt, _now());
    }
    final values = definition.readValues(model);

    final targets = <ColumnDefinition>[
      for (final column in definition.columns)
        if (!column.primaryKey &&
            (changed == null ||
                changed.contains(column.name) ||
                (updatedAt != null && column.name == updatedAt.name)))
          column,
    ];
    // Degenerate table with only key columns: perform a no-op assignment.
    final effective = targets.isEmpty ? <ColumnDefinition>[key] : targets;

    final dialect = dialectOf(executor);
    final writer = SqlWriter(dialect: dialect)
      ..write('UPDATE ${definition.qualifiedNameFor(dialect)} SET ');
    for (final (index, column) in effective.indexed) {
      if (index > 0) writer.write(', ');
      writer
        ..writeIdentifier(column.name)
        ..write(' = ');
      writer.bindTyped(column.sqlType, values[column.name]);
    }
    _writeKeyWhere(writer, key, values[key.name]);
    final result = await _writes.update(model, writer, timeout: timeout);
    await definition.lifecycleFor(model)?.afterUpdate();
    return result;
  }

  /// Alias for [insert], matching the model lookup API.
  Future<TModel> create(TModel model, {Duration? timeout}) =>
      insert(model, timeout: timeout);

  /// Inserts [model] when its primary key is unset, otherwise updates it.
  Future<TModel> save(TModel model, {Duration? timeout}) {
    final key = definition.singlePrimaryKey;
    final value = definition.readColumn(model, key);
    return value == null
        ? insert(model, timeout: timeout)
        : update(model, timeout: timeout);
  }

  /// Deletes the row identified by [model]'s primary key.
  ///
  /// When the table supports soft deletes, the row is marked (its soft-delete
  /// column is set to the current time) and [model] is updated to match; use
  /// [forceDelete] to remove it for good. Returns whether a row was affected.
  /// Lifecycle hooks ([TikalModel.beforeDelete] / [TikalModel.afterDelete]) run
  /// around the statement.
  Future<bool> delete(TModel model, {Duration? timeout}) async {
    await definition.lifecycleFor(model)?.beforeDelete();
    final deleted = definition.deletedAtColumn;
    final key = definition.singlePrimaryKey;
    final value = definition.readColumn(model, key);

    final bool affected;
    if (deleted == null) {
      affected = await _hardDeleteByKey(key, value, timeout);
    } else {
      final stamp = _now();
      affected = await _softDeleteByKey(key, value, deleted, stamp, timeout);
      if (affected) {
        definition.writeColumn(model, deleted, stamp);
        definition.syncOriginal(model);
      }
    }
    if (affected) await definition.lifecycleFor(model)?.afterDelete();
    return affected;
  }

  /// Deletes the row whose primary key equals [id].
  ///
  /// Soft-deletes when the table supports it. Returns whether a row was
  /// affected.
  Future<bool> deleteById(Object id, {Duration? timeout}) {
    final deleted = definition.deletedAtColumn;
    final key = definition.singlePrimaryKey;
    if (deleted == null) return _hardDeleteByKey(key, id, timeout);
    return _softDeleteByKey(key, id, deleted, _now(), timeout);
  }

  /// Permanently removes [model]'s row with a real `DELETE`.
  ///
  /// Use it to bypass soft deletes. Lifecycle hooks run around the statement.
  Future<bool> forceDelete(TModel model, {Duration? timeout}) async {
    await definition.lifecycleFor(model)?.beforeDelete();
    final key = definition.singlePrimaryKey;
    final value = definition.readColumn(model, key);
    final affected = await _hardDeleteByKey(key, value, timeout);
    if (affected) {
      definition.resetChanges(model);
      await definition.lifecycleFor(model)?.afterDelete();
    }
    return affected;
  }

  /// Permanently removes the row whose primary key equals [id].
  Future<bool> forceDeleteById(Object id, {Duration? timeout}) =>
      _hardDeleteByKey(definition.singlePrimaryKey, id, timeout);

  void _writeKeyWhere(SqlWriter writer, ColumnDefinition key, Object? value) {
    writer.write(' WHERE ');
    _KeyFilter<TModel>(key, value, null).writeTo(writer);
  }

  QueryBuilder<TModel> _byKey(
    ColumnDefinition key,
    Object? value,
    Duration? timeout, {
    bool excludeDeleted = false,
  }) {
    final builder = query().withTrashed().where(
      _KeyFilter<TModel>(
        key,
        value,
        excludeDeleted ? definition.deletedAtColumn : null,
      ),
    );
    return timeout == null ? builder : builder.timeout(timeout);
  }

  /// Clears the soft-delete mark of [model]'s row.
  ///
  /// Returns whether a row was affected. Throws [TikalModelException] when the
  /// table does not support soft deletes.
  Future<bool> restore(TModel model, {Duration? timeout}) async {
    final deleted = definition.deletedAtColumn;
    if (deleted == null) {
      throw TikalModelException(
        'Table "${definition.name}" does not support soft deletes.',
      );
    }
    final key = definition.singlePrimaryKey;
    final affected = await _byKey(
      key,
      definition.readColumn(model, key),
      timeout,
    ).restore();
    if (affected > 0) {
      definition.writeColumn(model, deleted, null);
      definition.syncOriginal(model);
    }
    return affected > 0;
  }

  /// Loads the row whose primary key equals [id], or `null` when absent.
  ///
  /// Soft-deleted rows are treated as absent; use `withTrashed().where(...)` or
  /// `onlyTrashed()` to reach them.
  Future<TModel?> findById(Object id, {Duration? timeout}) async {
    final statement = _byKey(
      definition.singlePrimaryKey,
      id,
      timeout,
      excludeDeleted: true,
    ).toSql();
    final result = await executor.query(
      '${statement.sql} LIMIT 1',
      parameters: statement.parameters,
      timeout: timeout,
    );
    final row = result.firstOrNull;
    return row == null ? null : definition.fromRow(row);
  }

  /// Like [findById] but throws [TikalEntityNotFoundException] when absent.
  Future<TModel> requireById(Object id, {Duration? timeout}) async =>
      await findById(id, timeout: timeout) ??
      (throw TikalEntityNotFoundException(
        table: definition.name,
        primaryKey: <String, Object?>{definition.singlePrimaryKey.name: id},
      ));

  QueryBuilder<TModel> _queryWhere(
    SqlPredicate<TModel>? where,
    Duration? timeout,
  ) {
    var builder = query();
    if (where != null) builder = builder.where(where);
    if (timeout != null) builder = builder.timeout(timeout);
    return builder;
  }

  /// The first row matching [where], or `null` when there is none.
  Future<TModel?> findOne({
    SqlPredicate<TModel>? where,
    List<OrderBy<TModel>>? orderBy,
    Duration? timeout,
  }) => find(
    where: where,
    orderBy: orderBy,
    limit: 1,
    timeout: timeout,
  ).then((rows) => rows.isEmpty ? null : rows.first);

  /// Runs a `SELECT` and maps every returned row into a model.
  ///
  /// This is the collection-building companion to the fluent [query] builder;
  /// both emit the same SQL. Use whichever reads better at the call site.
  Future<List<TModel>> find({
    SqlPredicate<TModel>? where,
    List<OrderBy<TModel>>? orderBy,
    int? limit,
    int? offset,
    Duration? timeout,
  }) {
    var builder = _queryWhere(where, timeout);
    if (orderBy != null) {
      for (final term in orderBy) {
        builder = builder.orderByTerm(term);
      }
    }
    if (limit != null) builder = builder.limit(limit);
    if (offset != null) builder = builder.offset(offset);
    return builder.get();
  }

  /// Every row of the table.
  Future<List<TModel>> findAll({Duration? timeout}) => find(timeout: timeout);

  /// The number of rows matching [where].
  Future<int> count({SqlPredicate<TModel>? where, Duration? timeout}) =>
      _queryWhere(where, timeout).count();

  /// Whether any row matches [where].
  Future<bool> exists({SqlPredicate<TModel>? where, Duration? timeout}) =>
      _queryWhere(where, timeout).exists();

  Future<bool> _hardDeleteByKey(
    ColumnDefinition key,
    Object? value,
    Duration? timeout,
  ) async => await _byKey(key, value, timeout).forceDelete() > 0;

  Future<bool> _softDeleteByKey(
    ColumnDefinition key,
    Object? value,
    ColumnDefinition deleted,
    DateTime stamp,
    Duration? timeout,
  ) async =>
      await _byKey(
        key,
        value,
        timeout,
        excludeDeleted: true,
      ).update({deleted: stamp}) >
      0;

  (List<ColumnDefinition>, List<Map<String, Object?>>) _prepareInsert(
    List<TModel> list,
  ) {
    for (final model in list) {
      _validate(model, forInsert: true);
    }
    final now = _now();
    for (final model in list) {
      _stampInsert(model, now);
    }

    final valueMaps = <Map<String, Object?>>[
      for (final model in list) definition.readValues(model),
    ];
    final columns = <ColumnDefinition>[
      for (final column in definition.columns)
        if (column.required ||
            valueMaps.any((values) => values[column.name] != null))
          column,
    ];

    return (columns, valueMaps);
  }

  void _stampInsert(TModel model, DateTime now) {
    final created = definition.createdAtColumn;
    if (created != null && definition.readColumn(model, created) == null) {
      definition.writeColumn(model, created, now);
    }
    final updated = definition.updatedAtColumn;
    if (updated != null) {
      definition.writeColumn(model, updated, now);
    }
  }

  void _validate(TModel model, {required bool forInsert}) {
    final errors = <String>[
      ...(definition.lifecycleFor(model)?.validate() ?? const <String>[]),
      ...definition.validate(model, forInsert: forInsert),
    ];
    if (errors.isNotEmpty) {
      throw TikalValidationException(errors);
    }
  }

  Future<TModel> _persist(
    TModel model,
    Duration? timeout, {
    required bool runHooks,
    UpsertSpec? spec,
  }) async {
    _validate(model, forInsert: true);
    if (runHooks) await definition.lifecycleFor(model)?.beforeInsert();
    _stampInsert(model, _now());
    _validate(model, forInsert: true);
    final result = await _writes.insert(model, spec: spec, timeout: timeout);
    if (runHooks) await definition.lifecycleFor(model)?.afterInsert();
    return result;
  }

  @override
  String toString() =>
      'Repository(${definition.qualifiedName}, executor: ${executor.runtimeType})';
}

/// Keyed operations preserve predicate order and do not add grouping parentheses.
final class _KeyFilter<T> extends SqlPredicate<T> {
  const _KeyFilter(this.key, this.value, this.deleted);
  final ColumnDefinition key;
  final Object? value;
  final ColumnDefinition? deleted;
  @override
  void writeTo(SqlWriter writer) {
    ColumnComparison<T, Object?>(key, SqlOperator.equal, value).writeTo(writer);
    if (deleted case final column?) {
      writer.write(' AND ');
      ColumnNullCheck<T>(column, isNull: true).writeTo(writer);
    }
  }
}
