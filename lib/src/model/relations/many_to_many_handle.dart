// Model
import 'relation_key.dart';
import 'many_to_many_relation.dart';

// Query
import '../../query/sql/sql_writer.dart';

// Database
import '../../database/query_result.dart';

// Query
import '../../query/dialects/dialect.dart';

// Database
import '../../database/query_executor.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// Model
import '../metadata/column_definition.dart';

// Query
import '../../query/expressions/sql_predicate.dart';

/// Explicit batched join-table writes for an existing source.
/// Targets are existing models or Dart primary-key values; models are never saved.
final class ManyToManyHandle<S extends Object, T extends Object> {
  /// Binds join metadata to an existing source and a transaction-capable executor.
  /// Throws ArgumentError for invalid batchSize or TikalModelException for composite keys.
  ManyToManyHandle({
    required this.relation,
    required this.source,
    required this.executor,
    this.batchSize = 1000,
  }) {
    if (batchSize < 1 || batchSize > 65535) {
      throw ArgumentError.value(batchSize, 'batchSize');
    }
    relation.source.singlePrimaryKey;
    relation.target.singlePrimaryKey;
  }

  /// Explicit join metadata, including which side owns writes.
  final ManyToManyRelation<S, T> relation;

  /// Existing source model; its primary key must be assigned.
  final S source;

  /// Executor reused for every statement in the operation.
  final QueryExecutor executor;

  /// Requested batch size, capped by the engine's parameter limit.
  final int batchSize;

  ColumnDefinition get _sourceKey => relation.source.singlePrimaryKey;
  ColumnDefinition get _targetKey => relation.target.singlePrimaryKey;
  String _table(QueryExecutor tx) =>
      tx.dialect.strategy.qualifiedName(relation.joinTable, relation.schema);
  Map<RelationKey, Object> _ids(Iterable<Object> values) {
    final ids = <RelationKey, Object>{};
    for (final value in values) {
      final id = _id(value);
      ids[_key(id)] = id;
    }
    return ids;
  }

  Object _id(Object value) {
    final id = value is T
        ? relation.target.readColumn(value, _targetKey)
        : value;
    if (id == null) {
      throw const TikalModelException(
        'Attach targets must have assigned primary keys.',
      );
    }
    relation.target.validateKeyValue(_targetKey, id);
    return id;
  }

  RelationKey _key(Object? value) => RelationKey(_targetKey.encodeValue(value));

  void _checkWritable() {
    if (!relation.writable) {
      throw const TikalUnsupportedException(
        'The inverse many-to-many side is read-only.',
      );
    }
  }

  Future<R> _withTargets<R>(
    Iterable<Object> targets,
    Future<R> Function(QueryExecutor, Object, Map<RelationKey, Object>) action,
  ) {
    _checkWritable();
    final ids = _ids(targets);
    return _atomic((tx, id) => action(tx, id, ids));
  }

  Future<R> _atomic<R>(Future<R> Function(QueryExecutor, Object) action) async {
    _checkWritable();
    final current = executor;
    if (current is! TransactionExecutor) {
      throw const TikalUnsupportedException(
        'Join writes require TransactionExecutor.',
      );
    }
    final sourceId = relation.source.readColumn(source, _sourceKey);
    if (sourceId == null) {
      throw const TikalModelException(
        'The source must have an assigned primary key.',
      );
    }
    return (current as TransactionExecutor).transaction((tx) async {
      final dialect = tx.dialect.strategy;
      final writer = SqlWriter(dialect: tx.dialect)
        ..write(
          'SELECT ${dialect.quote(_sourceKey.name)} FROM ${relation.source.qualifiedNameFor(tx.dialect)} WHERE ',
        );
      ColumnComparison<S, Object?>(
        _sourceKey,
        SqlOperator.equal,
        sourceId,
      ).writeTo(writer);
      writer.write(dialect.writeLockClause);
      final locked = await tx.query(writer.sql, parameters: writer.parameters);
      if (locked.isEmpty) {
        throw TikalEntityNotFoundException(
          table: relation.source.name,
          primaryKey: {_sourceKey.name: sourceId},
        );
      }
      return action(tx, sourceId);
    });
  }

  /// Adds edges idempotently, returning the number of inserted join rows.
  /// Throws TikalUnsupportedException on the inverse side or without transactions.
  /// Keys use Object to support converted Dart keys without a second key generic.
  /// Invalid target types throw [TikalModelException] with table/column/type;
  /// target keys are validated before source locking or any SQL.
  Future<int> attach(Iterable<Object> targets) => _withTargets(
    targets,
    (tx, id, ids) => _attach(tx, id, ids.values.toList()),
  );

  /// Removes the selected edges, or every edge when targets is omitted.
  /// Throws TikalUnsupportedException on the inverse side or without transactions.
  /// Uses Dart keys, not encoded SQL values, with the same validation as [attach].
  Future<int> detach([Iterable<Object>? targets]) {
    if (targets != null) {
      return _withTargets(
        targets,
        (tx, id, ids) => _detach(tx, id, ids.values.toList()),
      );
    }
    return _atomic((tx, id) async {
      final writer = SqlWriter(dialect: tx.dialect)
        ..write('DELETE FROM ${_table(tx)} WHERE ');
      _sourcePredicate(writer, id);
      return tx.execute(writer.sql, parameters: writer.parameters);
    });
  }

  /// Replaces the edge set and returns the attached/detached Dart key values.
  /// The whole diff runs in one transaction/savepoint. Throws
  /// TikalUnsupportedException on the inverse side or without transactions.
  Future<({List<Object> attached, List<Object> detached})> sync(
    Iterable<Object> targets,
  ) => _withTargets(targets, (tx, id, desired) async {
    final current = await _current(tx, id);
    final attached = [
      for (final entry in desired.entries)
        if (!current.containsKey(entry.key)) entry.value,
    ];
    final detached = [
      for (final entry in current.entries)
        if (!desired.containsKey(entry.key)) entry.value,
    ];
    await _detach(tx, id, detached);
    await _attach(tx, id, attached);
    return (
      attached: List<Object>.unmodifiable(attached),
      detached: List<Object>.unmodifiable(detached),
    );
  });

  /// Toggles each distinct target once and returns attached/detached Dart keys.
  /// Throws TikalUnsupportedException on the inverse side or without transactions.
  Future<({List<Object> attached, List<Object> detached})> toggle(
    Iterable<Object> targets,
  ) => _withTargets(targets, (tx, id, desired) async {
    final current = await _current(tx, id);
    final attached = [
      for (final entry in desired.entries)
        if (!current.containsKey(entry.key)) entry.value,
    ];
    final detached = [
      for (final entry in desired.entries)
        if (current.containsKey(entry.key)) entry.value,
    ];
    await _detach(tx, id, detached);
    await _attach(tx, id, attached);
    return (
      attached: List<Object>.unmodifiable(attached),
      detached: List<Object>.unmodifiable(detached),
    );
  });

  void _sourcePredicate(SqlWriter writer, Object id) {
    writer
      ..writeIdentifier(relation.joinColumn)
      ..write(' = ');
    writer.bindTyped(_sourceKey.sqlType, _sourceKey.encodeValue(id));
  }

  int _size(QueryExecutor tx, int reserved, int width) {
    final maximum = (tx.dialect.strategy.maxParameters - reserved) ~/ width;
    return batchSize < maximum ? batchSize : maximum;
  }

  Future<int> _attach(QueryExecutor tx, Object id, List<Object> ids) async {
    var affected = 0;
    final size = _size(tx, 0, 2);
    for (var offset = 0; offset < ids.length; offset += size) {
      final batch = ids.skip(offset).take(size).toList();
      final dialect = tx.dialect.strategy;
      final writer = SqlWriter(dialect: tx.dialect);
      dialect.insertIgnore(writer, () {
        writer.write(
          '${_table(tx)} (${dialect.quote(relation.joinColumn)}, ${dialect.quote(relation.inverseJoinColumn)}) VALUES ',
        );
        for (final (index, key) in batch.indexed) {
          if (index > 0) writer.write(', ');
          writer.write('(');
          writer.bindTyped(_sourceKey.sqlType, _sourceKey.encodeValue(id));
          writer.write(', ');
          writer.bindTyped(_targetKey.sqlType, _targetKey.encodeValue(key));
          writer.write(')');
        }
      });
      affected += await tx.execute(writer.sql, parameters: writer.parameters);
    }
    return affected;
  }

  Future<int> _detach(QueryExecutor tx, Object id, List<Object> ids) async {
    var affected = 0;
    final size = _size(tx, 1, 1);
    for (var offset = 0; offset < ids.length; offset += size) {
      final writer = SqlWriter(dialect: tx.dialect)
        ..write('DELETE FROM ${_table(tx)} WHERE ');
      _sourcePredicate(writer, id);
      writer.write(' AND ');
      ColumnInList<S, Object>(
        ColumnDefinition(
          name: relation.inverseJoinColumn,
          sqlType: _targetKey.sqlType,
          encode: _targetKey.encode,
        ),
        ids.skip(offset).take(size).toList(),
      ).writeTo(writer);
      affected += await tx.execute(writer.sql, parameters: writer.parameters);
    }
    return affected;
  }

  Future<Map<RelationKey, Object>> _current(QueryExecutor tx, Object id) async {
    final dialect = tx.dialect.strategy;
    final writer = SqlWriter(dialect: tx.dialect)
      ..write(
        'SELECT ${dialect.quote(relation.inverseJoinColumn)} FROM ${_table(tx)} WHERE ',
      );
    _sourcePredicate(writer, id);
    final rows = await tx.query(writer.sql, parameters: writer.parameters);
    final result = <RelationKey, Object>{};
    for (final row in rows.rows) {
      final value = relation.target
          .bindingFor(_targetKey)
          .decodeFrom(
            TikalRow(
              columnNames: [_targetKey.name],
              values: [row[relation.inverseJoinColumn]],
            ),
          );
      if (value != null) result[_key(value)] = value;
    }
    return result;
  }
}
