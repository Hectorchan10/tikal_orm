// Database
import 'tikal_database.dart';

// Query
import 'query/query_builder.dart';

// Model
import 'model/model_registry.dart';

// Repository
import 'repository/repository.dart';

// Config
import 'config/database_config.dart';

// Errors
import 'errors/tikal_exceptions.dart';

// Executor
import 'executor/query_executor.dart';
import 'executor/transaction_isolation.dart';

/// Optional default database. Explicit repositories remain independent.
abstract final class Tikal {
  static TikalDatabase? _database;
  static ModelRegistry? _models;
  static Future<void>? _configuring;
  static Future<void>? _closing;

  /// The validated default connection. Await [configure] before using it.
  static TikalDatabase get database {
    final current = _database;
    if (current == null ||
        _configuring != null ||
        _closing != null ||
        !current.isOpen) {
      throw const TikalConfigurationException(
        'Await Tikal.configure before using the default database.',
      );
    }
    return current;
  }

  /// Opens one default pool, or adopts [connection] without creating another.
  /// Supply exactly one of database and connection, plus optional models.
  /// Repeated calls with the same configuration
  /// instance or connection share initialization. Close before replacing it.
  /// [close] also closes an adopted connection.
  static Future<void> configure({
    DatabaseConfig? database,
    TikalDatabase? connection,
    ModelRegistry? models,
  }) {
    if ((database == null) == (connection == null)) {
      throw const TikalConfigurationException(
        'Supply either database or connection.',
      );
    }
    if (_closing != null) {
      throw const TikalConfigurationException(
        'Await Tikal.close before configuring again.',
      );
    }
    final current = _database;
    if (current != null) {
      if (models != null && !identical(models, _models)) {
        throw const TikalConfigurationException(
          'Close Tikal before replacing its model registry.',
        );
      }
      if (!identical(current, connection) &&
          !identical(current.config, database)) {
        throw const TikalConfigurationException(
          'Tikal is already configured. Close it before replacing the default database.',
        );
      }
      return _configuring ?? current.open();
    }
    final candidate = connection ?? TikalDatabase(database!);
    _database = candidate;
    _models = models;
    return _configuring = _initialize(candidate)
        .whenComplete(() => _configuring = null);
  }

  static Future<void> _initialize(TikalDatabase candidate) async {
    try {
      await candidate.open();
    } catch (_) {
      _database = null;
      _models = null;
      await candidate.close();
      rethrow;
    }
  }

  /// Closes the default connection, including pending initialization.
  static Future<void> close() =>
      _closing ??= _close().whenComplete(() => _closing = null);

  static Future<void> _close() async {
    try {
      await _configuring;
    } finally {
      final current = _database;
      _database = null;
      _models = null;
      await current?.close();
    }
  }

  /// Resolves a configured model using the default or an explicit executor.
  /// Generated metadata is imported only at initialization. Typed column holders
  /// still require a Dart import in modules that use them.
  static ModelAccess<T> model<T extends Object>({QueryExecutor? executor}) {
    final registry = _models;
    if (registry == null) {
      throw const TikalConfigurationException(
        'Configure through generated/tikal.dart, or supply models to the runtime Tikal.configure.',
      );
    }
    return ModelAccess(
      Repository<T>(
        executor: executor ?? database,
        definition: registry.definitionFor<T>(),
      ),
    );
  }

  /// Inserts when the primary key is unset, otherwise updates changed values.
  static Future<T> save<T extends Object>(
    T value, {
    QueryExecutor? executor,
    Duration? timeout,
  }) => model<T>(executor: executor).save(value, timeout: timeout);

  /// Finds one model by primary key, or returns null when absent.
  static Future<T?> find<T extends Object>(
    Object id, {
    QueryExecutor? executor,
    Duration? timeout,
  }) => model<T>(executor: executor).find(id, timeout: timeout);

  /// Lists all models in the default query scope.
  static Future<List<T>> all<T extends Object>({
    QueryExecutor? executor,
    Duration? timeout,
  }) => model<T>(executor: executor).repository.findAll(timeout: timeout);

  /// Starts an immutable typed query on the default or explicit executor.
  static QueryBuilder<T> query<T extends Object>({QueryExecutor? executor}) =>
      model<T>(executor: executor).query();

  /// Deletes one model, respecting its table's soft-delete behavior.
  static Future<bool> delete<T extends Object>(
    T value, {
    QueryExecutor? executor,
    Duration? timeout,
  }) => model<T>(executor: executor).delete(value, timeout: timeout);

  /// Delegates to the default database. Use the supplied executor explicitly;
  /// global queries keep using the default pool, even inside this callback.
  static Future<T> transaction<T>(
    Future<T> Function(QueryExecutor tx) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) => database.transaction(
    action,
    isolation: isolation,
    readOnly: readOnly,
    timeout: timeout,
  );
}

/// Typed model entry point. This extension type allocates no wrapper and delegates
/// all persistence to [repository]. Repository.find keeps its existing filtered
/// list signature; this facade's find delegates to Repository.findById.
extension type ModelAccess<T extends Object>(Repository<T> repository) {
  QueryBuilder<T> query() => repository.query();
  Future<T?> find(Object id, {Duration? timeout}) =>
      repository.findById(id, timeout: timeout);
  Future<T> create(T model, {Duration? timeout}) =>
      repository.insert(model, timeout: timeout);
  Future<T> save(T model, {Duration? timeout}) =>
      repository.save(model, timeout: timeout);
  Future<bool> delete(T model, {Duration? timeout}) =>
      repository.delete(model, timeout: timeout);
}
