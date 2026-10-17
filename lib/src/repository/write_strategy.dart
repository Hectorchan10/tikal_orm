import 'package:uuid/uuid.dart';

// Query
import '../query/dialect.dart';

// Config
import '../config/sql_type.dart';

// Query
import '../query/sql_writer.dart';

// Executor
import '../executor/query_result.dart';

// Model
import '../model/table_definition.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';

// Model
import '../model/column_definition.dart';

typedef PreparedRows = (List<ColumnDefinition>, List<Map<String, Object?>>);
typedef SingleWrite<T> = Future<T> Function(
  QueryExecutor executor,
  T model,
  UpsertSpec? spec,
);

/// Conflict metadata; MySQL uses it only to locate the resulting row.
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
abstract class WriteStrategy<T extends Object> {
  const WriteStrategy(this.executor, this.definition);
  final QueryExecutor executor;
  final TableDefinition<T> definition;
  SqlDialect get dialect => dialectOf(executor);
  Future<T> insert(T model, {UpsertSpec? spec, Duration? timeout});
  Future<T> update(T model, SqlWriter writer, {Duration? timeout});
  Future<List<T>> insertAll(
    List<T> models,
    PreparedRows Function() prepare,
    SingleWrite<T> insertOne,
    Duration? timeout,
  );
  Future<List<T>> upsert(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec spec,
    SingleWrite<T> insertOne,
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
        writer.bindTyped(column.sqlType, map[column.name]);
      }
      writer.write(')');
    }
    return writer;
  }

  (SqlWriter, List<ColumnDefinition>) writeModel(T model) {
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

final class ReturningWriteStrategy<T extends Object> extends WriteStrategy<T> {
  const ReturningWriteStrategy(super.executor, super.definition);
  void _returning(SqlWriter writer) =>
      writer.write(' RETURNING ${definition.quotedColumnsFor(dialect)}');
  @override
  Future<T> insert(T model, {UpsertSpec? spec, Duration? timeout}) =>
      update(model, writeModel(model).$1, timeout: timeout);
  @override
  Future<T> update(T model, SqlWriter writer, {Duration? timeout}) async {
    _returning(writer);
    return load(model, await run(writer, timeout));
  }

  @override
  Future<List<T>> insertAll(
    List<T> models,
    PreparedRows Function() prepare,
    SingleWrite<T> insertOne,
    Duration? timeout,
  ) async {
    final (columns, values) = prepare();
    if (columns.isEmpty) {
      return [
        for (final model in models) await insertOne(executor, model, null),
      ];
    }
    return _many(writeRows(columns, values), timeout);
  }

  @override
  Future<List<T>> upsert(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec spec,
    SingleWrite<T> insertOne,
    Duration? timeout,
  ) {
    final (columns, values) = prepared;
    final writer = writeRows(columns, values);
    dialect.strategy.upsertClause(
      writer,
      spec.conflictColumns,
      spec.targets(columns),
    );
    return _many(writer, timeout);
  }

  Future<List<T>> _many(SqlWriter writer, Duration? timeout) async {
    _returning(writer);
    return (await run(
      writer,
      timeout,
    )).rows.map(definition.fromRow).toList(growable: false);
  }
}

final class ReloadWriteStrategy<T extends Object> extends WriteStrategy<T> {
  const ReloadWriteStrategy(super.executor, super.definition);
  @override
  Future<T> insert(T model, {UpsertSpec? spec, Duration? timeout}) async {
    final key = definition.singlePrimaryKey;
    if (key.sqlType == SqlType.uuid &&
        key.hasDefault &&
        definition.readColumn(model, key) == null) {
      definition.writeColumn(model, key, const Uuid().v4());
    }
    final (writer, columns) = writeModel(model);
    if (spec != null) {
      final targets = spec.targets(columns);
      dialect.strategy.upsertClause(
        writer,
        spec.conflictColumns,
        targets,
        primaryKey: targets.isEmpty ? key.name : null,
      );
    }
    final result = await run(writer, timeout);
    if (spec == null &&
        key.autoIncrement &&
        definition.readColumn(model, key) == null &&
        result.lastInsertId != null) {
      definition.writeColumn(model, key, result.lastInsertId);
    }
    return _reload(model, spec?.conflictColumns ?? [key], timeout);
  }

  @override
  Future<T> update(T model, SqlWriter writer, {Duration? timeout}) async {
    await run(writer, timeout);
    return _reload(model, [definition.singlePrimaryKey], timeout);
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
      writer.bindTyped(column.sqlType, definition.readColumn(model, column));
    }
    return load(model, await run(writer, timeout));
  }

  Future<List<T>> _batch(
    List<T> models,
    SingleWrite<T> insertOne,
    UpsertSpec? spec,
    Duration? timeout,
  ) async {
    Future<List<T>> action(QueryExecutor tx) async => [
      for (final model in models) await insertOne(tx, model, spec),
    ];
    final current = executor;
    return current is TransactionExecutor
        ? (current as TransactionExecutor).transaction(action, timeout: timeout)
        : action(current);
  }

  @override
  Future<List<T>> insertAll(
    List<T> models,
    PreparedRows Function() prepare,
    SingleWrite<T> insertOne,
    Duration? timeout,
  ) => _batch(models, insertOne, null, timeout);
  @override
  Future<List<T>> upsert(
    List<T> models,
    PreparedRows prepared,
    UpsertSpec spec,
    SingleWrite<T> insertOne,
    Duration? timeout,
  ) => _batch(models, insertOne, spec, timeout);
}
