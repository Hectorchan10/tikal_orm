// Model
import 'model_column.dart';
import 'table_definition.dart';

// Query
import '../query/query_builder.dart';

// Repository
import '../repository/repository.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';

/// The shared contract of the two explicit, typed batch loaders.
abstract interface class RelationLoader<S extends Object, R> {
  Future<Map<S, R>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  });
}

/// Loads targets in bounded IN queries; missing or soft-deleted targets are null.
final class BelongsToRelation<S extends Object, T extends Object, K>
    implements RelationLoader<S, T?> {
  const BelongsToRelation({
    required this.foreignKey,
    required this.targetKey,
    required this.target,
  });
  final ModelColumn<S, K> foreignKey;
  final ModelColumn<T, K> targetKey;
  final TableDefinition<T> target;
  @override
  Future<Map<S, T?>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  }) async {
    _validateBatchSize(batchSize);
    final models = sources.toList();
    final ids = models.map(foreignKey.read).whereType<K>().toSet().toList();
    final byId = <K?, T>{};
    final repository = Repository<T>(executor: executor, definition: target);
    for (final batch in _batches(ids, batchSize)) {
      final rows = await repository.where(targetKey.isIn(batch)).get();
      for (final row in rows) {
        byId[targetKey.read(row)] = row;
      }
    }
    return {for (final model in models) model: byId[foreignKey.read(model)]};
  }
}

/// Loads children in bounded IN queries, respecting target soft-delete scopes.
final class HasManyRelation<S extends Object, T extends Object, K>
    implements RelationLoader<S, List<T>> {
  const HasManyRelation({
    required this.sourceKey,
    required this.foreignKey,
    required this.target,
  });
  final ModelColumn<S, K> sourceKey;
  final ModelColumn<T, K> foreignKey;
  final TableDefinition<T> target;
  @override
  Future<Map<S, List<T>>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  }) async {
    _validateBatchSize(batchSize);
    final models = sources.toList();
    final ids = models.map(sourceKey.read).whereType<K>().toSet().toList();
    final grouped = <K?, List<T>>{};
    final repository = Repository<T>(executor: executor, definition: target);
    for (final batch in _batches(ids, batchSize)) {
      final rows = await repository.where(foreignKey.isIn(batch)).get();
      for (final row in rows) {
        (grouped[foreignKey.read(row)] ??= []).add(row);
      }
    }
    return {
      for (final model in models)
        model: List.unmodifiable(grouped[sourceKey.read(model)] ?? <T>[]),
    };
  }
}

/// A query result plus typed relationship maps, without hidden entity mutation.
final class LoadedRelations<T extends Object> {
  LoadedRelations._(List<T> models, this._relations)
    : models = List.unmodifiable(models);
  final List<T> models;
  final Map<RelationLoader<T, Object?>, Map<T, Object?>> _relations;

  /// Retrieves the result belonging to this loader and entity.
  /// The cast recovers only the loader's own output type at this map boundary.
  R related<R>(RelationLoader<T, R> relation, T model) {
    final values = _relations[relation];
    if (values == null || !values.containsKey(model)) {
      throw TikalModelException(
        'Relation or entity was not included in this query result.',
      );
    }
    return values[model] as R;
  }
}

/// A terminal composition over the existing immutable QueryBuilder.
final class RelationQuery<T extends Object> {
  RelationQuery._(
    this.query,
    Iterable<RelationLoader<T, Object?>> relations,
    this.batchSize,
  ) : relations = List.unmodifiable(relations.toSet()) {
    _validateBatchSize(batchSize);
  }
  final QueryBuilder<T> query;
  final List<RelationLoader<T, Object?>> relations;
  final int batchSize;
  Future<LoadedRelations<T>> get() async {
    final models = await query.get();
    final loaded = <RelationLoader<T, Object?>, Map<T, Object?>>{};
    for (final relation in relations) {
      loaded[relation] = await relation.load(
        query.executor,
        models,
        batchSize: batchSize,
      );
    }
    return LoadedRelations._(models, loaded);
  }
}

/// Add relations after query clauses; ordinary get() still returns `List<T>`.
extension QueryRelations<T extends Object> on QueryBuilder<T> {
  RelationQuery<T> withRelations(
    Iterable<RelationLoader<T, Object?>> relations, {
    int batchSize = 1000,
  }) => RelationQuery._(this, relations, batchSize);
}

/// Start an unfiltered query with explicit eager loading.
extension RepositoryRelations<T extends Object> on Repository<T> {
  RelationQuery<T> withRelations(
    Iterable<RelationLoader<T, Object?>> relations, {
    int batchSize = 1000,
  }) => query().withRelations(relations, batchSize: batchSize);
}

void _validateBatchSize(int size) {
  if (size < 1 || size > 65535) {
    throw ArgumentError.value(
      size,
      'batchSize',
      'Use 1–65535 bound identifiers per query.',
    );
  }
}

Iterable<List<K>> _batches<K>(List<K> values, int size) sync* {
  for (var offset = 0; offset < values.length; offset += size) {
    yield values.sublist(
      offset,
      offset + size > values.length ? values.length : offset + size,
    );
  }
}
