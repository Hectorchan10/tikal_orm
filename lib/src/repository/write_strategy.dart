import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

// SQL
import '../sql/sql_type.dart';
import '../sql/sql_param.dart';
import '../query/sql/sql_writer.dart';

// Database
import '../database/query_result.dart';

// Query
import '../query/dialects/dialect.dart';

// Database
import '../database/query_executor.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Model
import '../model/relations/relation_key.dart';
import '../model/metadata/table_definition.dart';
import '../model/metadata/column_definition.dart';

@internal
typedef PreparedRows = (List<ColumnDefinition>, List<Map<String, Object?>>);

/// Conflict metadata; MySQL uses it only to locate the resulting row.
@internal
final class UpsertSpec {
  const UpsertSpec(this.conflictColumns, this.updateColumns);
  final List<ColumnDefinition> conflictColumns;
  final List<ColumnDefinition>? updateColumns;
  List<ColumnDefinition> targets(List<ColumnDefinition> columns) =>
      updateColumns ??
      [
        for (final column in columns)
          if (!column.primaryKey &&
              !conflictColumns.any((c) => c.name == column.name))
            column,
      ];
}

/// Persistence mechanics only. The repository owns validation, hooks and clocks.
@internal
abstract class WriteStrategy<T extends Object> {
  const WriteStrategy(this.executor, this.definition);
  final QueryExecutor executor;
  final TableDefinition<T> definition;
  SqlDialect get dialect => executor.dialect;
  Future<T> insert(T model, {Duration? timeout});
  Future<T> update(
    T model,
    SqlWriter writer, {
    Duration? timeout,
    int? expectedVersion,
  });
  Future<List<T>> insertAll(
    List<T> models,
    PreparedRows Function() prepare,
    Duration? timeout,
  );
  Future<List<T>> upsert(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec spec,
    Duration? timeout,
  );

  SqlWriter writeRows(
    List<ColumnDefinition> columns,
    List<Map<String, Object?>> values,
  ) {
    final writer = SqlWriter(dialect: dialect)
      ..write('INSERT INTO ${definition.qualifiedNameFor(dialect)} ');
    if (columns.isEmpty) {
      writer.write(dialect.strategy.emptyInsert);
      return writer;
    }
    writer.write(
      '(${columns.map((c) => dialect.strategy.quote(c.name)).join(', ')}) VALUES ',
    );
    for (final (row, map) in values.indexed) {
      if (row > 0) writer.write(', ');
      writer.write('(');
      for (final (index, column) in columns.indexed) {
        if (index > 0) writer.write(', ');
        writer.bindTyped(
          column.sqlType,
          definition.encodeWriteValue(column, map[column.name]),
        );
      }
      writer.write(')');
    }
    return writer;
  }

  void checkParameterCount(int count) {
    final limit = dialect.strategy.maxParameters;
    if (count > limit) {
      throw TikalUnsupportedException(
        'One row in "${definition.name}" needs $count parameters; '
        '${dialect.name} allows $limit.',
      );
    }
  }

  Future<R> bulkTransaction<R>(
    Future<R> Function(QueryExecutor) action,
    Duration? timeout,
  ) {
    final current = executor;
    if (current is! TransactionExecutor) {
      throw const TikalUnsupportedException(
        'Bulk writes require TransactionExecutor for atomic batches.',
      );
    }
    return (current as TransactionExecutor).transaction(
      action,
      timeout: timeout,
    );
  }

  (T, Map<String, Object?>) stage(TikalRow row) {
    final model = definition.fromRowUntracked(row);
    return (model, definition.encodedValues(model));
  }

  List<(T, Map<String, Object?>)> stageRows(
    SqlWriter writer,
    List<ColumnDefinition> columns,
    List<TikalRow> rows,
    UpsertSpec? spec,
  ) {
    final staged = rows.map(stage).toList(growable: false);
    if (columns.isEmpty || rows.length < 2) return staged;
    final parameters = writer.parameters.cast<SqlParam>();
    final count = parameters.length ~/ columns.length;
    var keys = spec?.conflictColumns ?? definition.primaryKeyColumns;
    if (keys.isEmpty ||
        keys.any((k) => !columns.contains(k)) ||
        keys.any(
          (k) => Iterable<int>.generate(count).any(
            (i) =>
                parameters[i * columns.length + columns.indexOf(k)].value ==
                null,
          ),
        )) {
      keys = columns;
    }
    final indices = keys.map(columns.indexOf).toList(growable: false);
    // Reuse the structural SQL-value key used by batched relation loading.
    final positions = <RelationKey, List<int>>{};
    for (var i = count - 1; i >= 0; i--) {
      final key = RelationKey([
        for (final index in indices)
          parameters[i * columns.length + index].value,
      ]);
      (positions[key] ??= []).add(i);
    }
    final ordered = <(int, (T, Map<String, Object?>))>[];
    for (final (index, result) in staged.indexed) {
      final matches =
          positions[RelationKey([for (final key in keys) result.$2[key.name]])];
      // Triggers or engine collation can transform correlation values. Retain
      // database order for such unmatched results rather than inventing a match.
      ordered.add((
        matches == null || matches.isEmpty
            ? count + index
            : matches.removeLast(),
        result,
      ));
    }
    ordered.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final entry in ordered) entry.$2];
  }

  /// Populates generated UUID keys only when the engine has no server UUID default.
  void prepareGeneratedKeys(T model) {
    final values = definition.readValues(model);
    prepareGeneratedValues(values);
    for (final key in definition.primaryKeyColumns) {
      if (values[key.name] != definition.readColumn(model, key)) {
        definition.writeColumn(model, key, values[key.name]);
      }
    }
  }

  void prepareGeneratedValues(Map<String, Object?> values) {
    if (!dialect.strategy.generatesUuidOnClient) return;
    for (final key in definition.primaryKeyColumns) {
      if (key.sqlType == SqlType.uuid &&
          key.hasDefault &&
          values[key.name] == null) {
        values[key.name] = definition
            .bindingFor(key)
            .decodeFrom(
              TikalRow(columnNames: [key.name], values: [const Uuid().v4()]),
            );
      }
    }
  }

  (SqlWriter, List<ColumnDefinition>) writeModel(T model) {
    prepareGeneratedKeys(model);
    final values = definition.readValues(model);
    final columns = [
      for (final column in definition.columns)
        if (!(values[column.name] == null &&
            (column.hasDefault || column.autoIncrement)))
          column,
    ];
    return (writeRows(columns, [values]), columns);
  }

  Future<QueryResult> run(SqlWriter writer, Duration? timeout) => executor
      .query(writer.sql, parameters: writer.parameters, timeout: timeout);
  T load(T model, QueryResult result) {
    final row = result.firstOrNull;
    if (row == null) {
      throw TikalEntityNotFoundException(
        table: definition.name,
        primaryKey: definition.primaryKeyValues(model),
      );
    }
    definition.loadInto(model, row);
    return model;
  }
}

@internal
final class ReturningWriteStrategy<T extends Object> extends WriteStrategy<T> {
  const ReturningWriteStrategy(super.executor, super.definition);
  void _returning(SqlWriter writer) =>
      writer.write(' RETURNING ${definition.quotedColumnsFor(dialect)}');
  @override
  Future<T> insert(T model, {Duration? timeout}) =>
      update(model, writeModel(model).$1, timeout: timeout);
  @override
  Future<T> update(
    T model,
    SqlWriter writer, {
    Duration? timeout,
    int? expectedVersion,
  }) async {
    _returning(writer);
    final result = await run(writer, timeout);
    if (expectedVersion != null && result.rows.isEmpty) {
      throw TikalConcurrencyException(
        table: definition.name,
        expectedVersion: expectedVersion,
      );
    }
    return load(model, result);
  }

  @override
  Future<List<T>> insertAll(
    List<T> models,
    PreparedRows Function() prepare,
    Duration? timeout,
  ) async {
    return _many(prepare(), null, timeout);
  }

  @override
  Future<List<T>> upsert(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec spec,
    Duration? timeout,
  ) => _many(prepared, spec, timeout);

  Future<List<T>> _many(
    PreparedRows prepared,
    UpsertSpec? spec,
    Duration? timeout,
  ) async {
    final (columns, values) = prepared;
    // Every column contributes exactly one binding, including NULL/native values.
    // Conflict assignments use EXCLUDED and add no parameters.
    checkParameterCount(columns.length);
    final size = columns.isEmpty
        ? 1
        : dialect.strategy.maxParameters ~/ columns.length;
    final rows = await bulkTransaction((tx) async {
      final strategy = ReturningWriteStrategy<T>(tx, definition);
      final rows = <(T, Map<String, Object?>)>[];
      for (var start = 0; start < values.length; start += size) {
        final end = start + size < values.length ? start + size : values.length;
        final writer = strategy.writeRows(columns, values.sublist(start, end));
        if (spec != null) {
          dialect.strategy.upsertClause(
            writer,
            spec.conflictColumns,
            spec.targets(columns),
          );
        }
        strategy._returning(writer);
        rows.addAll(
          stageRows(
            writer,
            columns,
            (await strategy.run(writer, timeout)).rows,
            spec,
          ),
        );
      }
      return rows;
    }, timeout);
    // Do not publish persisted snapshots until all statements have succeeded.
    return [for (final (model, snapshot) in rows) publish(model, snapshot)];
  }

  T publish(T model, Map<String, Object?> snapshot) {
    definition.state.sync(model, snapshot);
    return model;
  }
}

@internal
final class ReloadWriteStrategy<T extends Object> extends WriteStrategy<T> {
  const ReloadWriteStrategy(super.executor, super.definition);

  /// Writes and reloads on one transaction when the executor supports it.
  /// Without TransactionExecutor, another writer may change the row before reload.
  @override
  Future<T> insert(T model, {Duration? timeout}) =>
      _atomic((strategy) => strategy._insert(model, timeout), timeout);

  Future<T> _insert(T model, Duration? timeout) async {
    final key = definition.singlePrimaryKey;
    final writer = writeModel(model).$1;
    final result = await run(writer, timeout);
    if (key.autoIncrement &&
        definition.readColumn(model, key) == null &&
        result.lastInsertId != null) {
      definition.writeColumn(
        model,
        key,
        definition
            .bindingFor(key)
            .decodeFrom(
              TikalRow(columnNames: [key.name], values: [result.lastInsertId]),
            ),
      );
    }
    return _reload(model, [key], timeout);
  }

  /// Updates and reloads on one transaction when the executor supports it.
  /// Without TransactionExecutor, write and reload have no atomicity guarantee.
  @override
  Future<T> update(
    T model,
    SqlWriter writer, {
    Duration? timeout,
    int? expectedVersion,
  }) => _atomic(
    (strategy) => strategy._update(model, writer, timeout, expectedVersion),
    timeout,
  );

  Future<T> _update(
    T model,
    SqlWriter writer,
    Duration? timeout,
    int? expectedVersion,
  ) async {
    final result = await run(writer, timeout);
    if (expectedVersion != null && result.affectedRows == 0) {
      throw TikalConcurrencyException(
        table: definition.name,
        expectedVersion: expectedVersion,
      );
    }
    return _reload(model, [definition.singlePrimaryKey], timeout);
  }

  Future<T> _atomic(
    Future<T> Function(ReloadWriteStrategy<T>) action,
    Duration? timeout,
  ) {
    final current = executor;
    if (current is TransactionExecutor &&
        !(current is TransactionStateExecutor &&
            (current as TransactionStateExecutor).isInTransaction)) {
      return (current as TransactionExecutor).transaction(
        (tx) => action(ReloadWriteStrategy<T>(tx, definition)),
        timeout: timeout,
      );
    }
    return action(this);
  }

  Future<T> _reload(
    T model,
    List<ColumnDefinition> columns,
    Duration? timeout,
  ) async {
    final writer = SqlWriter(dialect: dialect)
      ..write(
        'SELECT ${definition.quotedColumnsFor(dialect)} FROM ${definition.qualifiedNameFor(dialect)} WHERE ',
      );
    for (final (index, column) in columns.indexed) {
      if (index > 0) writer.write(' AND ');
      writer
        ..writeIdentifier(column.name)
        ..write(' = ');
      writer.bindTyped(
        column.sqlType,
        column.encodeValue(definition.readColumn(model, column)),
      );
    }
    return load(model, await run(writer, timeout));
  }

  Future<List<T>> _batch(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec? spec,
    Duration? timeout,
  ) async {
    final key = definition.singlePrimaryKey;
    final reloadColumns = spec?.conflictColumns ?? [key];
    checkParameterCount(reloadColumns.length);
    final values = prepared.$2;
    // MySQL retains single-row inserts and key reloads, including per-row defaults.
    List<ColumnDefinition> columnsFor(Map<String, Object?> map) => [
      for (final column in definition.columns)
        if (!(map[column.name] == null &&
            (column.hasDefault || column.autoIncrement)))
          column,
    ];
    for (final map in values) {
      checkParameterCount(columnsFor(map).length);
    }
    final rows = await bulkTransaction((tx) async {
      final strategy = ReloadWriteStrategy<T>(tx, definition);
      final rows = <TikalRow>[];
      for (final map in values) {
        final columns = columnsFor(map);
        final writer = strategy.writeRows(columns, [map]);
        if (spec != null) {
          final targets = spec.targets(columns);
          dialect.strategy.upsertClause(
            writer,
            spec.conflictColumns,
            targets,
            primaryKey: targets.isEmpty ? key.name : null,
          );
        }
        final result = await strategy.run(writer, timeout);
        final reload = SqlWriter(dialect: dialect)
          ..write(
            'SELECT ${definition.quotedColumnsFor(dialect)} FROM ${definition.qualifiedNameFor(dialect)} WHERE ',
          );
        for (final (index, column) in reloadColumns.indexed) {
          if (index > 0) reload.write(' AND ');
          reload
            ..writeIdentifier(column.name)
            ..write(' = ');
          final generated =
              spec == null &&
              column == key &&
              key.autoIncrement &&
              map[key.name] == null;
          // Driver-generated keys are already SQL values, not converter inputs.
          reload.bindTyped(
            column.sqlType,
            generated
                ? result.lastInsertId
                : column.encodeValue(map[column.name]),
          );
        }
        final row = (await strategy.run(reload, timeout)).firstOrNull;
        if (row == null) {
          throw TikalEntityNotFoundException(
            table: definition.name,
            primaryKey: {
              for (final column in reloadColumns) column.name: map[column.name],
            },
          );
        }
        rows.add(row);
      }
      return rows.map(stage).toList(growable: false);
    }, timeout);
    for (final (index, (model, snapshot)) in rows.indexed) {
      definition.copyValues(model, models[index]);
      definition.state.sync(models[index], snapshot);
    }
    return models;
  }

  @override
  Future<List<T>> insertAll(
    List<T> models,
    PreparedRows Function() prepare,
    Duration? timeout,
  ) => _batch(models, prepare(), null, timeout);
  @override
  Future<List<T>> upsert(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec spec,
    Duration? timeout,
  ) => _batch(models, prepared, spec, timeout);
}
