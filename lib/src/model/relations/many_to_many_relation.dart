// Model
import 'relations.dart';
import 'relation_key.dart';

// SQL
import '../../query/sql/sql_writer.dart';

// Database
import '../../database/query_result.dart';

// Repository
import '../../repository/repository.dart';

// Query
import '../../query/dialects/dialect.dart';

// Model
import '../metadata/table_definition.dart';

// Database
import '../../database/query_executor.dart';

// Model
import '../metadata/column_definition.dart';

// Query
import '../../query/expressions/sql_predicate.dart';

/// Explicit batch loader for a join table that has no model class.
/// Target soft-delete scopes apply. Loading returns immutable relation maps;
/// it never populates model list fields or writes the join table.
final class ManyToManyRelation<S extends Object, T extends Object>
    implements RelationLoader<S, List<T>> {
  /// Declares join metadata; an inverse loader must set writable to false.
  const ManyToManyRelation({
    required this.source,
    required this.target,
    required this.joinTable,
    required this.joinColumn,
    required this.inverseJoinColumn,
    this.schema,
    this.writable = true,
  });

  /// Source model definition.
  final TableDefinition<S> source;

  /// Target model definition, including soft-delete metadata.
  final TableDefinition<T> target;

  /// Explicit join-table name.
  final String joinTable;

  /// Join column referencing the source key.
  final String joinColumn;

  /// Join column referencing the target key.
  final String inverseJoinColumn;

  /// Optional namespace of the join table.
  final String? schema;

  /// Whether this is the owning side, which can mutate join rows.
  final bool writable;

  /// Loads join edges and target rows using bounded IN queries.
  /// Throws ArgumentError for invalid batchSize, or TikalModelException for
  /// composite keys. Query failures propagate without modifying source entities.
  @override
  Future<Map<S, List<T>>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  }) async {
    if (batchSize < 1 || batchSize > 65535) {
      throw ArgumentError.value(batchSize, 'batchSize');
    }
    final dialect = executor.dialect.strategy;
    final size = batchSize < dialect.maxParameters
        ? batchSize
        : dialect.maxParameters;
    final sourceKey = source.singlePrimaryKey;
    final targetKey = target.singlePrimaryKey;
    final models = sources.toList();
    final sourceIds = <RelationKey, Object?>{};
    for (final model in models) {
      final value = source.readColumn(model, sourceKey);
      if (value != null) {
        sourceIds[RelationKey(sourceKey.encodeValue(value))] = value;
      }
    }
    final ids = sourceIds.values.toList();
    final edges = <RelationKey, List<RelationKey>>{};
    final targetIds = <RelationKey, Object?>{};
    for (var offset = 0; offset < ids.length; offset += size) {
      final batch = ids.skip(offset).take(size).toList();
      final writer = SqlWriter(dialect: executor.dialect)
        ..write(
          'SELECT ${dialect.quote(joinColumn)} AS ${dialect.quote('__source')}, ${dialect.quote(inverseJoinColumn)} AS ${dialect.quote('__target')} FROM ${dialect.qualifiedName(joinTable, schema)} WHERE ',
        );
      ColumnInList<S, Object?>(
        ColumnDefinition(
          name: joinColumn,
          sqlType: sourceKey.sqlType,
          encode: sourceKey.encode,
        ),
        batch,
      ).writeTo(writer);
      final rows = await executor.query(
        writer.sql,
        parameters: writer.parameters,
      );
      for (final row in rows.rows) {
        Object? decode<M extends Object>(
          TableDefinition<M> table,
          ColumnDefinition key,
          String alias,
        ) => table
            .bindingFor(key)
            .decodeFrom(
              TikalRow(columnNames: [key.name], values: [row[alias]]),
            );
        final sourceId = decode(source, sourceKey, '__source');
        final targetId = decode(target, targetKey, '__target');
        final from = RelationKey(sourceKey.encodeValue(sourceId));
        final to = RelationKey(targetKey.encodeValue(targetId));
        (edges[from] ??= []).add(to);
        targetIds[to] = targetId;
      }
    }
    final byKey = <RelationKey, T>{};
    final idsToLoad = targetIds.values.toList();
    final repository = Repository(executor: executor, definition: target);
    for (var offset = 0; offset < idsToLoad.length; offset += size) {
      final batch = idsToLoad.skip(offset).take(size).toList();
      final rows = await repository
          .where(ColumnInList<T, Object?>(targetKey, batch))
          .get();
      for (final row in rows) {
        byKey[RelationKey(
              targetKey.encodeValue(target.readColumn(row, targetKey)),
            )] =
            row;
      }
    }
    return {
      for (final model in models)
        model: List<T>.unmodifiable([
          for (final key
              in edges[RelationKey(
                    sourceKey.encodeValue(source.readColumn(model, sourceKey)),
                  )] ??
                  <RelationKey>[])
            ?byKey[key],
        ]),
    };
  }
}
