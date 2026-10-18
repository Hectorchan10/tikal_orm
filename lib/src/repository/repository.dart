// Model
import 'write_strategy.dart';

// Query
import '../query/query_builder.dart';
import '../query/sql/sql_writer.dart';
import '../query/dialects/dialect.dart';

// Database
import '../database/query_executor.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Query
import '../query/expressions/order_by.dart';

// Database
import '../database/transaction_isolation.dart';

// Model
import '../model/metadata/table_definition.dart';

// Query
import '../query/expressions/sql_predicate.dart';

// Model
import '../model/metadata/column_definition.dart';

/// Persistence, validation, clocks and lifecycle hooks for one model mapping.
/// Explicit executors keep this path independent from application clients.
final class Repository<TModel extends Object> {
  /// Creates a repository that runs its statements through [executor].
  /// Throws [TikalUnsupportedException] for unsupported column bindings.
  ///
  /// [clock] supplies the current time for timestamps and soft deletes and
  /// defaults to [DateTime.now]; pass a fixed function in tests.
  Repository({required this.executor, required this.definition, this.clock}) {
    definition.validateDialect(executor.dialect);
  }

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

  DateTime _now() => (clock ?? DateTime.now)().toUtc();

  /// Returns a repository bound to [executor], sharing this definition.
  ///
  /// Use this when a callback supplies a transaction or borrowed session.
  Repository<TModel> usingExecutor(QueryExecutor executor) =>
      Repository<TModel>(
        executor: executor,
        definition: definition,
        clock: clock,
      );

  /// Starts a fluent `SELECT` for this model with no clauses yet.
  QueryBuilder<TModel> query() => QueryBuilder<TModel>(
    executor: executor,
    definition: definition,
    clock: clock,
  );

  /// Starts a fluent `SELECT` filtered by [predicate].
  ///
  /// Returns an immutable [QueryBuilder] seeded with the first condition.
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
  /// A version counter is initialized to one, replacing any supplied value.
  ///
  /// The write strategy populates server-generated values on [model]. When the
  /// table declares `createdAt` / `updatedAt` columns, both are stamped with the
  /// current time unless already set. Lifecycle hooks (`ModelLifecycle.beforeInsert`
  /// / `ModelLifecycle.afterInsert`) run around the statement.
  Future<TModel> insert(TModel model, {Duration? timeout}) async =>
      _persist(model, timeout, runHooks: true);

  /// Inserts every model in [models]. MySQL uses ordered individual inserts
  /// in a transaction (savepoint when already in one), without lifecycle hooks.
  ///
  /// The column list is the union of the columns that carry a value in at least
  /// one model plus every required column. A model that omits an included
  /// column binds `NULL` for it, which must be allowed by the column (nullable
  /// or defaulted). PostgreSQL/SQLite use parameter-bounded RETURNING batches;
  /// MySQL retains single-row inserts with key reloads. Results follow input
  /// order using bound keys/values to correlate RETURNING rows; unmatched values
  /// transformed by triggers/collations retain database order within their batch.
  /// Inputs receive no generated fields or snapshots before the operation succeeds.
  /// Use the returned rows for generated values on PostgreSQL/SQLite.
  ///
  /// All statements run in one transaction/savepoint. Throws
  /// [TikalUnsupportedException] before SQL if a row exceeds the parameter limit
  /// or the executor lacks [TransactionExecutor]. Decode failures also roll back.
  /// A later rollback of an outer transaction does not rewind published snapshots.
  ///
  /// Timestamps are applied to every model, but **lifecycle hooks do not run**
  /// for bulk inserts; use [insert] when a model needs its hooks.
  Future<List<TModel>> insertAll(
    Iterable<TModel> models, {
    Duration? timeout,
  }) async {
    final list = models.toList(growable: false);
    if (list.isEmpty) return [];
    return _writes.insertAll(list, () => _prepareInsert(list), timeout);
  }

  WriteStrategy<TModel> get _writes =>
      executor.dialect.strategy.supportsReturning
      ? ReturningWriteStrategy(executor, definition)
      : ReloadWriteStrategy(executor, definition);

  /// Inserts or updates [models] using parameter-bounded conflict batches.
  ///
  /// Conflicting rows are matched on [conflictColumns], which must correspond to
  /// a unique index or the primary key. Matching rows are updated with the
  /// values proposed by the insert, using the `EXCLUDED` pseudo-table,
  /// unless [updateColumns] is empty, in which case conflicts are left alone
  /// (`DO NOTHING`). [updateColumns] defaults to every inserted column that is
  /// neither part of the conflict target nor a primary key.
  ///
  /// Throws [TikalUnsupportedException] for versioned models.
  /// Timestamps are applied; like [insertAll], lifecycle hooks do not run.
  /// MySQL uses ON DUPLICATE KEY on any unique index. conflictColumns serves
  /// only to reload each result; a different unique conflict may fail the reload.
  /// MySQL performs individual statements in a transaction/savepoint.
  /// The atomicity, result ordering and executor requirements of [insertAll] apply.
  Future<List<TModel>> upsert(
    Iterable<TModel> models, {
    required List<ColumnDefinition> conflictColumns,
    List<ColumnDefinition>? updateColumns,
    Duration? timeout,
  }) async {
    _rejectVersionedBulk();
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
  /// Versioned models atomically increment their counter and check the persisted
  /// version (or the supplied version for detached models). The counter must be
  /// positive and must not be edited. Throws [TikalConcurrencyException] when the
  /// key/version pair no longer matches, including a concurrently deleted row.
  /// Clean models perform no SQL and do not increment their version.
  ///
  /// When [model] was loaded from the database (or written by a previous save),
  /// only the columns that actually changed are written, so concurrent edits to
  /// other columns are not clobbered; pass `onlyChanged: false` to write every
  /// non-key column. A model with no snapshot (never loaded or saved) writes all
  /// non-key columns. When nothing changed, no statement is sent.
  ///
  /// When the table declares an `updatedAt` column it is stamped with the
  /// current time. Lifecycle hooks (`ModelLifecycle.beforeUpdate` /
  /// `ModelLifecycle.afterUpdate`) run around the statement. When no row matches,
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

    final result = await _updateValues(model, values, effective, timeout);
    await definition.lifecycleFor(model)?.afterUpdate();
    return result;
  }

  Future<TModel> _updateValues(
    TModel model,
    Map<String, Object?> values,
    List<ColumnDefinition> targets,
    Duration? timeout,
  ) {
    final version = definition.versionColumn;
    int? expected;
    if (version != null) {
      final snapshot = definition.state.originalValues(model);
      final current = definition.readColumn(model, version);
      final original = snapshot?[version.name] ?? current;
      if (original is! int || original < 1 || current != original) {
        throw TikalValidationException([
          'Version must be a positive integer and cannot be edited.',
        ]);
      }
      expected = original;
    }
    final dialect = executor.dialect;
    final writer = SqlWriter(dialect: dialect)
      ..write('UPDATE ${definition.qualifiedNameFor(dialect)} SET ');
    var index = 0;
    for (final column in targets.where((c) => c != version)) {
      if (index++ > 0) writer.write(', ');
      writer
        ..writeIdentifier(column.name)
        ..write(' = ');
      writer.bindTyped(
        column.sqlType,
        definition.encodeWriteValue(column, values[column.name]),
      );
    }
    if (version != null) {
      if (index > 0) writer.write(', ');
      writer
        ..writeIdentifier(version.name)
        ..write(' = ')
        ..writeIdentifier(version.name)
        ..write(' + 1');
    }
    final key = definition.singlePrimaryKey;
    _writeKeyWhere(writer, key, values[key.name]);
    if (version != null) {
      writer
        ..write(' AND ')
        ..writeIdentifier(version.name)
        ..write(' = ');
      writer.bindTyped(version.sqlType, expected);
    }
    return _writes.update(
      model,
      writer,
      timeout: timeout,
      expectedVersion: expected,
    );
  }

  void _rejectVersionedBulk() {
    if (definition.versionColumn != null) {
      throw const TikalUnsupportedException(
        'Versioned models require individual updates; bulk writes and upserts cannot check each version.',
      );
    }
  }

  Future<bool> _versionedSoftWrite(
    TModel model,
    Object? deletedValue,
    Duration? timeout,
  ) async {
    final deleted = definition.deletedAtColumn!;
    final updated = definition.updatedAtColumn;
    final values = definition.readValues(model)..[deleted.name] = deletedValue;
    if (updated != null) {
      values[updated.name] = deletedValue is DateTime ? deletedValue : _now();
    }
    await _updateValues(model, values, [deleted, ?updated], timeout);
    return true;
  }

  /// Inserts a model with no persisted snapshot, even if its key is assigned.
  /// Loaded or previously written models use change-based updates instead.
  Future<TModel> save(TModel model, {Duration? timeout}) =>
      definition.isPersisted(model)
      ? update(model, timeout: timeout)
      : insert(model, timeout: timeout);

  /// Deletes the row identified by [model]'s primary key.
  ///
  /// When the table supports soft deletes, the row is marked (its soft-delete
  /// column is set to the current time) and [model] is updated to match; use
  /// [forceDelete] to remove it for good. Returns whether a row was affected.
  /// Lifecycle hooks (`ModelLifecycle.beforeDelete` / `ModelLifecycle.afterDelete`) run
  /// around the statement.
  /// Physical deletion of versioned models checks the original snapshot version
  /// (or the supplied positive version for detached models). Throws
  /// [TikalConcurrencyException] when the key/version pair no longer matches.
  Future<bool> delete(TModel model, {Duration? timeout}) async {
    await definition.lifecycleFor(model)?.beforeDelete();
    final deleted = definition.deletedAtColumn;
    final key = definition.singlePrimaryKey;
    final value = definition.readColumn(model, key);

    final bool affected;
    if (deleted == null) {
      final version = definition.versionColumn;
      if (version == null) {
        affected = await _hardDeleteByKey(key, value, timeout);
      } else {
        final original =
            definition.state.originalValues(model)?[version.name] ??
            definition.readColumn(model, version);
        if (original is! int || original < 1) {
          throw TikalValidationException([
            'Version must be a positive integer.',
          ]);
        }
        final writer = SqlWriter(dialect: executor.dialect)
          ..write(
            'DELETE FROM ${definition.qualifiedNameFor(executor.dialect)}',
          );
        _writeKeyWhere(writer, key, value);
        writer
          ..write(' AND ')
          ..writeIdentifier(version.name)
          ..write(' = ');
        writer.bindTyped(version.sqlType, original);
        final count = await executor.execute(
          writer.sql,
          parameters: writer.parameters,
          timeout: timeout,
        );
        if (count == 0) {
          throw TikalConcurrencyException(
            table: definition.name,
            expectedVersion: original,
          );
        }
        affected = true;
      }
    } else {
      final stamp = _now();
      affected = definition.versionColumn != null
          ? await _versionedSoftWrite(model, stamp, timeout)
          : await _softDeleteByKey(key, value, deleted, stamp, timeout);
      if (affected) {
        definition.writeColumn(model, deleted, stamp);
        if (definition.updatedAtColumn case final updated?) {
          definition.writeColumn(model, updated, stamp);
        }
        definition.syncOriginal(model);
      }
    }
    if (affected) await definition.lifecycleFor(model)?.afterDelete();
    return affected;
  }

  /// Deletes the row whose primary key equals [id].
  ///
  /// Soft-deletes when the table supports it. Returns whether a row was
  /// affected. Versioned soft deletes require [delete] with a model;
  /// throws [TikalUnsupportedException] when only the key is supplied.
  /// Accepts the Dart primary-key value, including converted domain keys.
  /// No second key generic is required. Invalid types throw [TikalModelException]
  /// before SQL, naming the table, column and received type.
  Future<bool> deleteById(Object id, {Duration? timeout}) {
    final deleted = definition.deletedAtColumn;
    final key = definition.singlePrimaryKey;
    definition.validateKeyValue(key, id);
    if (deleted == null) return _hardDeleteByKey(key, id, timeout);
    _rejectVersionedBulk();
    return _softDeleteByKey(key, id, deleted, _now(), timeout);
  }

  /// Permanently removes [model]'s row with a real `DELETE`.
  ///
  /// Bypasses soft deletes and optimistic version checks, including for versioned
  /// models. Lifecycle hooks run around the statement.
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
  /// Accepts the Dart primary-key value, including converted domain keys.
  /// No second key generic is required. Invalid types throw [TikalModelException]
  /// before SQL, naming the table, column and received type.
  Future<bool> forceDeleteById(Object id, {Duration? timeout}) =>
      _hardDeleteByKey(definition.singlePrimaryKey, id, timeout);

  void _writeKeyWhere(SqlWriter writer, ColumnDefinition key, Object? value) {
    definition.validateKeyValue(key, value);
    writer.write(' WHERE ');
    _KeyFilter<TModel>(key, value, null).writeTo(writer);
  }

  QueryBuilder<TModel> _byKey(
    ColumnDefinition key,
    Object? value,
    Duration? timeout, {
    bool excludeDeleted = false,
    DateTime Function()? clockOverride,
  }) {
    definition.validateKeyValue(key, value);
    final base = clockOverride == null
        ? query()
        : QueryBuilder<TModel>(
            executor: executor,
            definition: definition,
            clock: clockOverride,
          );
    final builder = base.withTrashed().where(
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
    if (definition.versionColumn != null) {
      return _versionedSoftWrite(model, null, timeout);
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
  /// Accepts the Dart primary-key value, including converted domain keys.
  /// No second key generic is required. Invalid types throw [TikalModelException]
  /// before SQL, naming the table, column and received type.
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
  /// Accepts the Dart primary-key value, including converted domain keys.
  /// No second key generic is required. Invalid types throw [TikalModelException]
  /// before SQL, naming the table, column and received type.
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
        clockOverride: () => stamp,
      ).delete() >
      0;

  (List<ColumnDefinition>, List<Map<String, Object?>>) _prepareInsert(
    List<TModel> list,
  ) {
    for (final model in list) {
      _validate(model, forInsert: true);
    }
    final now = _now();
    final valueMaps = <Map<String, Object?>>[];
    final writes = _writes;
    for (final model in list) {
      final values = definition.readValues(model);
      if (definition.versionColumn case final version?) {
        values[version.name] = 1;
      }
      if (definition.createdAtColumn case final created?) {
        values[created.name] ??= now;
      }
      if (definition.updatedAtColumn case final updated?) {
        values[updated.name] = now;
      }
      writes.prepareGeneratedValues(values);
      valueMaps.add(values);
    }
    final columns = <ColumnDefinition>[
      for (final column in definition.columns)
        if (column.required ||
            valueMaps.any((values) => values[column.name] != null))
          column,
    ];

    return (columns, valueMaps);
  }

  void _initializeVersion(TModel model) {
    if (definition.versionColumn case final version?) {
      definition.writeColumn(model, version, 1);
    }
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
  }) async {
    _initializeVersion(model);
    _validate(model, forInsert: true);
    if (runHooks) await definition.lifecycleFor(model)?.beforeInsert();
    _stampInsert(model, _now());
    _validate(model, forInsert: true);
    final result = await _writes.insert(model, timeout: timeout);
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
