import 'dart:async';

// Config
import 'config/server_config.dart';

// Repository
import 'repository/repository.dart';

// Config
import 'config/database_config.dart';

// Database
import 'database/query_executor.dart';
import 'database/query_listener.dart';
import 'database/tikal_database.dart';

// Errors
import 'errors/tikal_exceptions.dart';

// Model
import 'model/metadata/model_registry.dart';

// Database
import 'database/transaction_isolation.dart';

/// Application client owning static model metadata and an explicitly opened database.
/// Construction has no connection side effects; configure never reconciles schema.
final class TikalClient {
  /// Creates an application client without opening a connection.
  // Keep the registry private while exposing a descriptive named argument.
  // ignore: prefer_initializing_formals
  TikalClient({required ModelRegistry models}) : _models = models;

  TikalDatabase? _database;
  final ModelRegistry _models;
  Future<void>? _configuring;
  Future<void>? _closing;
  final _scopeKey = Object();

  /// The validated default connection. Await [configure] before using it.
  TikalDatabase get database {
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
  /// Throws [TikalUnsupportedException] before opening for unsupported model columns.
  /// Supply exactly one of database and connection.
  /// Repeated calls with the same configuration
  /// instance or connection share initialization. Close before replacing it.
  /// [close] also closes an adopted connection.
  Future<void> configure({
    DatabaseConfig? database,
    TikalDatabase? connection,
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
      if (!identical(current, connection) &&
          !identical(current.config, database)) {
        throw const TikalConfigurationException(
          'Tikal is already configured. Close it before replacing the default database.',
        );
      }
      return _configuring ?? current.open();
    }
    final candidate = connection ?? TikalDatabase(database!);
    _models.validateDialect(candidate.dialect);
    _database = candidate;
    return _configuring = _initialize(candidate)
        .whenComplete(() => _configuring = null);
  }

  Future<void> _initialize(TikalDatabase candidate) async {
    try {
      await candidate.open();
    } catch (_) {
      _database = null;
      await candidate.close();
      rethrow;
    }
  }

  /// Closes the default connection, including pending initialization.
  Future<void> close() =>
      _closing ??= _close().whenComplete(() => _closing = null);

  Future<void> _close() async {
    try {
      await _configuring;
    } finally {
      final current = _database;
      _database = null;
      await current?.close();
    }
  }

  /// Observes queries on the configured database, including explicit transactions.
  /// Returns an idempotent function that unregisters the listener. Register after
  /// configure; close clears listeners. Events omit parameters and error details.
  void Function() onQuery(QueryListener listener) => database.onQuery(listener);

  /// Explicitly creates registered tables, constraints and indexes for development/tests.
  /// Never called by configure or queries; does not inspect, reconcile or migrate.
  /// Existing tables cause a query error. Generated registries supply the schema;
  /// manual registries must supply ModelRegistry.schema. Renders the entire plan
  /// before executing SQL. PostgreSQL/SQLite creation is transactional; MySQL DDL
  /// implicitly commits and can leave partially created objects after a failure.
  /// Schemas/databases must already exist; by default only public PostgreSQL
  /// schemas and the configured MySQL database are accepted. SQLite ignores schemas.
  /// Throws [TikalConfigurationException] for missing configuration/schema metadata,
  /// [TikalUnsupportedException] for unrepresentable DDL, or a query exception.
  /// Set allowExistingSchemas only for PostgreSQL: every referenced namespace is
  /// checked before DDL inside the creation transaction. Missing schemas fail;
  /// this helper never creates namespaces or changes privileges.
  Future<void> createTables({bool allowExistingSchemas = false}) async {
    final db = database;
    final registry = _models;
    final schema = registry.schema;
    if (schema == null) {
      throw const TikalConfigurationException(
        'Explicit table creation needs schema metadata. Regenerate or supply ModelRegistry.schema.',
      );
    }
    if (allowExistingSchemas && db.dialect != SqlDialect.postgres) {
      throw const TikalUnsupportedException(
        'allowExistingSchemas is PostgreSQL-only.',
      );
    }
    final requestedSchemas = <String, String>{};
    final config = db.config;
    for (final table in schema.tables) {
      final targets = <String>{table.schema ?? 'public'};
      for (final column in table.columns) {
        final reference = RegExp(r'^\s*"((?:[^"]|"")+)"\.')
            .firstMatch(column.references ?? '');
        if (reference != null) targets.add(reference[1]!.replaceAll('""', '"'));
      }
      for (final target in targets) {
        final allowed = switch (db.dialect) {
          SqlDialect.sqlite => true,
          SqlDialect.postgres => target == 'public' || allowExistingSchemas,
          SqlDialect.mysql =>
            target == 'public' ||
                config is ServerConfig && target == config.database,
        };
        if (allowExistingSchemas) requestedSchemas[target] = table.name;
        if (!allowed) {
          throw TikalConfigurationException(
            'Table "${table.name}" uses schema "$target". createTables does not create schemas/databases. Create it explicitly and use reviewed DDL for this schema.',
          );
        }
      }
    }
    final statements = schema.createSqlFor(
      db.dialect,
      definitions: registry.definitions,
    );
    Future<void> execute(QueryExecutor executor) async {
      for (final entry in requestedSchemas.entries) {
        final result = await executor.query(
          r'SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = $1',
          parameters: [entry.key],
        );
        if (result.rows.isEmpty) {
          throw TikalConfigurationException(
            'Table "${entry.value}" needs existing PostgreSQL schema "${entry.key}". Provision it explicitly before createTables.',
          );
        }
      }
      for (final sql in statements) {
        await executor.execute(sql);
      }
    }

    if (db.dialect == SqlDialect.mysql) {
      await execute(db);
    } else {
      await db.transaction(execute);
    }
  }

  /// Resolves a model using explicit executor, active transaction, then database.
  /// Obtain repositories inside the callback; previously obtained repositories
  /// retain their executor. Borrowed transaction repositories must not escape it.
  /// Throws [TikalConfigurationException] when an inherited scope has finished.
  /// The generated client supplies metadata explicitly, with no connection
  /// side effects. Modules using typed columns still import their generated holders.
  Repository<T> model<T extends Object>({QueryExecutor? executor}) {
    final registry = _models;
    return Repository<T>(
      executor: executor ?? _currentExecutor,
      definition: registry.definitionFor<T>(),
    );
  }

  QueryExecutor get _currentExecutor {
    final scope = Zone.current[_scopeKey] as _TransactionScope?;
    if (scope == null) return database;
    final executor = scope.executor;
    if (!scope.active ||
        (executor is TransactionStateExecutor &&
            !(executor as TransactionStateExecutor).isInTransaction)) {
      throw const TikalConfigurationException(
        'The inherited transaction has finished. Await all work inside its callback.',
      );
    }
    return executor;
  }

  /// Runs awaited work in a transaction inherited by model() calls in this Zone.
  /// Nested calls use the active executor's savepoint support. Explicit executors
  /// always win. Outside the callback, model() uses the default database again.
  /// Errors propagate after rollback; encoded model snapshots are not rewound.
  /// Throws [TikalUnsupportedException] if the active executor cannot nest.
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor tx) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) {
    final executor = _currentExecutor;
    if (executor is! TransactionExecutor) {
      throw const TikalUnsupportedException(
        'The active executor does not support transactions or savepoints.',
      );
    }
    return (executor as TransactionExecutor).transaction(
      (tx) async {
        final scope = _TransactionScope(tx);
        try {
          return await runZoned(
            () => action(tx),
            zoneValues: {_scopeKey: scope},
          );
        } finally {
          scope.active = false;
        }
      },
      isolation: isolation,
      readOnly: readOnly,
      timeout: timeout,
    );
  }
}

final class _TransactionScope {
  _TransactionScope(this.executor);
  final QueryExecutor executor;
  bool active = true;
}
