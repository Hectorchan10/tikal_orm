// Model
import 'relation_key.dart';
import '../metadata/model_column.dart';

// Query
import '../../query/query_builder.dart';

// Repository
import '../../repository/repository.dart';

// Query
import '../../query/dialects/dialect.dart';

// Model
import '../metadata/table_definition.dart';

// Database
import '../../database/query_executor.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

/// Explicit, typed batch loading without implicit per-entity queries.
/// Source keys are deduplicated and chunked into IN queries. Related entities
/// respect their own soft-delete scopes. Loaders do not mutate source models.
abstract interface class RelationLoader<S extends Object, R> {
  /// Loads relations in bounded batches, returning a value for each source model.
  /// Throws [ArgumentError] unless batchSize is between 1 and 65535.
  /// Throws [TikalQueryException] when a database query fails.
  Future<Map<S, R>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  });
}

/// Loads targets in bounded IN queries; missing or soft-deleted targets are null.
final class BelongsToRelation<S extends Object, T extends Object, K>
    implements RelationLoader<S, T?> {
  /// Creates a typed foreign-key lookup using the related table metadata.
  const BelongsToRelation({
    required this.foreignKey,
    required this.targetKey,
    required this.target,
  });

  /// Column containing the foreign key used by this loader.
  final ModelColumn<S, K> foreignKey;

  /// Related model key matched against the source foreign-key values.
  final ModelColumn<T, K> targetKey;

  /// Table definition used to decode the related models.
  final TableDefinition<T> target;

  /// Loads related rows in bounded batches.
  /// Throws [ArgumentError] for invalid batchSize and [TikalQueryException] on query failure.
  @override
  Future<Map<S, T?>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  }) async {
    _validateBatchSize(batchSize);
    final models = sources.toList();
    final ids = {
      for (final key in models.map(foreignKey.read).whereType<K>())
        RelationKey(foreignKey.encodeValue(key)): key,
    }.values.toList();
    final byId = <RelationKey, T>{};
    final repository = Repository<T>(executor: executor, definition: target);
    for (final batch in _batches(
      ids,
      batchSize < executor.dialect.strategy.maxParameters
          ? batchSize
          : executor.dialect.strategy.maxParameters,
    )) {
      final rows = await repository.where(targetKey.isIn(batch)).get();
      for (final row in rows) {
        byId[RelationKey(targetKey.encodeValue(targetKey.read(row)))] = row;
      }
    }
    return {
      for (final model in models)
        model:
            byId[RelationKey(foreignKey.encodeValue(foreignKey.read(model)))],
    };
  }
}

/// Loads children in bounded IN queries, respecting target soft-delete scopes.
final class HasManyRelation<S extends Object, T extends Object, K>
    implements RelationLoader<S, List<T>> {
  /// Creates a typed child loader matching source keys against foreign keys.
  const HasManyRelation({
    required this.sourceKey,
    required this.foreignKey,
    required this.target,
  });

  /// Source model key matched against the related foreign-key values.
  final ModelColumn<S, K> sourceKey;

  /// Column containing the foreign key used by this loader.
  final ModelColumn<T, K> foreignKey;

  /// Table definition used to decode the related models.
  final TableDefinition<T> target;

  /// Loads related rows in bounded batches.
  /// Throws [ArgumentError] for invalid batchSize and [TikalQueryException] on query failure.
  @override
  Future<Map<S, List<T>>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  }) async {
    _validateBatchSize(batchSize);
    final models = sources.toList();
    final ids = {
      for (final key in models.map(sourceKey.read).whereType<K>())
        RelationKey(sourceKey.encodeValue(key)): key,
    }.values.toList();
    final grouped = <RelationKey, List<T>>{};
    final repository = Repository<T>(executor: executor, definition: target);
    for (final batch in _batches(
      ids,
      batchSize < executor.dialect.strategy.maxParameters
          ? batchSize
          : executor.dialect.strategy.maxParameters,
    )) {
      final rows = await repository.where(foreignKey.isIn(batch)).get();
      for (final row in rows) {
        (grouped[RelationKey(foreignKey.encodeValue(foreignKey.read(row)))] ??=
                [])
            .add(row);
      }
    }
    return {
      for (final model in models)
        model: List.unmodifiable(
          grouped[RelationKey(sourceKey.encodeValue(sourceKey.read(model)))] ??
              <T>[],
        ),
    };
  }
}

/// A query result plus typed relationship maps, without hidden entity mutation.
final class LoadedRelations<T extends Object> {
  LoadedRelations._(List<T> models, this._relations)
    : models = List.unmodifiable(models);

  /// Immutable models returned by the base query.
  final List<T> models;
  final Map<RelationLoader<T, Object?>, Map<T, Object?>> _relations;

  /// Retrieves the result belonging to this loader and entity.
  /// The cast recovers only the loader's own output type at this map boundary.
  /// Throws [TikalModelException] if the loader or entity was not included.
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
/// Loads the base models once and then executes each requested batch loader.
/// Database failures propagate; use an explicit transaction executor when the base
/// query and related queries must see a consistent snapshot.
final class RelationQuery<T extends Object> {
  RelationQuery._(
    this.query,
    Iterable<RelationLoader<T, Object?>> relations,
    this.batchSize,
  ) : relations = List.unmodifiable(relations.toSet()) {
    _validateBatchSize(batchSize);
  }

  /// Base immutable query whose results will receive related values.
  final QueryBuilder<T> query;

  /// Explicit relation loaders, with duplicate loader values removed.
  final List<RelationLoader<T, Object?>> relations;

  /// Maximum number of identifiers bound in one relation query.
  final int batchSize;

  /// Executes the base query and the requested relation loaders.
  /// Missing belongs-to targets become null; missing child collections become empty lists.
  /// Throws [TikalQueryException] when a base or related query fails.
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
  /// Adds explicit eager loading without mutating the entities or the base query.
  /// Throws [ArgumentError] unless batchSize is between 1 and 65535.
  RelationQuery<T> withRelations(
    Iterable<RelationLoader<T, Object?>> relations, {
    int batchSize = 1000,
  }) => RelationQuery._(this, relations, batchSize);
}

/// Start an unfiltered query with explicit eager loading.
extension RepositoryRelations<T extends Object> on Repository<T> {
  /// Adds explicit eager loading without mutating the entities or the base query.
  /// Throws [ArgumentError] unless batchSize is between 1 and 65535.
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

/// Loads at most one child through a unique target foreign key, in bounded batches.
/// Missing or soft-deleted children are null. No source field is mutated.
final class OneToOneRelation<S extends Object, T extends Object, K>
    implements RelationLoader<S, T?> {
  /// Reuses the existing child loader; generated metadata requires a unique FK.
  OneToOneRelation({
    required ModelColumn<S, K> sourceKey,
    required ModelColumn<T, K> foreignKey,
    required TableDefinition<T> target,
  }) : _children = HasManyRelation(
         sourceKey: sourceKey,
         foreignKey: foreignKey,
         target: target,
       );

  final HasManyRelation<S, T, K> _children;

  /// Loads existing children, rejecting multiple matches instead of picking one.
  /// Throws [TikalModelException] for cardinality violations, [ArgumentError] for
  /// invalid batch sizes, or [TikalQueryException] when a query fails.
  @override
  Future<Map<S, T?>> load(
    QueryExecutor executor,
    Iterable<S> sources, {
    int batchSize = 1000,
  }) async {
    final rows = await _children.load(executor, sources, batchSize: batchSize);
    return Map.unmodifiable({
      for (final entry in rows.entries) entry.key: _single(entry.value),
    });
  }

  T? _single(List<T> rows) {
    if (rows.length > 1) {
      throw TikalModelException(
        'One-to-one target "${_children.target.name}" returned multiple rows; enforce a unique foreign key.',
      );
    }
    return rows.firstOrNull;
  }
}
