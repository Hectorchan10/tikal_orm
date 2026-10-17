# AGENTS.md

Keep this guidance short and aligned with code. Prefer focused changes and code
as the source of truth for README/CHANGELOG.

## Project

TikalORM (`tikal_orm`) is a framework-neutral Dart ORM for PostgreSQL, SQLite and
MySQL 8.0+ / MariaDB 10.5+. Runtime entry: `lib/tikal_orm.dart`; applications use
the generated entry point for automatic model configuration:

```dart
import 'generated/tikal.dart';
await Tikal.configure(database: SqliteConfig(path: 'app.db'));
final users = await Tikal.all<User>();
await Tikal.close();
```

PostgresConfig and MysqlConfig select pooled engines; SqliteConfig owns one handle.
Direct configuration requires no env/URL/credentials file or dialect argument.
fromEnvironment is optional. No secrets in diagnostics/generated files, mirrors,
import registration effects, hidden registries or runtime generation.

- Dart `^3.13.5`; version `0.0.1` in pubspec and tikalOrmVersion (keep synced).
- Engines: postgres `^3.5.20`, mysql_dart `^3.0.0`, sqlite3 `^3.0.0` (build hooks).
- crypto `^3.0.7` verifies migration history; analyzer `^14.5.0` is CLI-only.
- New dependencies: uuid `^4.6.0` replaces manual UUID v4; synchronized `^3.5.0`
  replaces async queues with locks; meta `^1.19.0` marks internal helpers; path
  `^1.9.1` computes generator paths. Analyzer/path emission never enter runtime.
- Dev: lints `^6.0.0`, test `^1.25.6`; recommended lints.

## Checks and layout

```bash
dart pub get
dart format .
dart analyze
dart test
# Consuming application, before analyzing/testing/building:
dart run tikal_orm:tikal generate
# Optional separate development task:
dart run tikal_orm:tikal generate --watch
```

All changes must leave formatting a no-op, analysis clean and tests green.

- `lib/src/config/`: engine configs, sql_type, internal config_parsing and
  server_config (shared immutable network settings/validation for pooled engines).
- `executor/`: query_executor (execution/dialect/transaction contracts),
  database_connection, engine adapters, named_query_mixin, postgres_params and
  driver_result_mapper. `lib/postgres.dart` is the optional PG binding entry.
- `seeding/`: Seeder annotation and static callback registry; no reflection or
  default connection side effects. Seeder analysis/emission live in generator/.
- `params/`: pure sql_param; internal named_params and portable_params encoders.
- `query/`: dialect strategies, immutable query_builder, sql_predicate, order_by,
  quoting and sql_writer.
- `model/`: annotations, metadata, change_tracker, model_state, model_registry,
  relations, decoders and optional legacy tikal_model.
- `repository/`: repository owns lifecycle/validation/clocks; write_strategy owns
  RETURNING versus write/reload mechanics.
- `schema/`: PostgreSQL-only schema/diff, migration, schema_inspector and guards.
- `generator/`: model_analyzer facade and internal parts model_parser,
  model_validator, field_validator, foreign_key_resolver, library_emitter and
  legacy_detector. Keep every generator source below 300 lines.
- `bin/tikal.dart`: compatibility entry point delegating to `lib/src/cli/`.
  CLI parts separate commands, configuration/input discovery, generation and watch;
  they stay outside the runtime barrel.
- `test/support/`: shared Account, generator fixture and executors.
- `.agents/skills/`, `utils/`: local guidance/helpers. No example/ or doc/ tree.

## Patrones

- Strategy: Dialect encapsulates SQL differences; WriteStrategy separates engine
  persistence mechanics; ChangeTracker separates legacy and plain snapshots.
- Template Method: NamedQueryMixin rewrites named values then delegates execution.
  SQLite retains its updatedRows-based execute; MySQL uses query.affectedRows.
- ModelAnalyzer remains a stable facade. Its internal parts share private AST
  helpers without exposing new public generator APIs. Generated models use no parts.

## Invariants

- Bind every value. Metadata identifiers use the dialect; never interpolate user
  values. PostgreSQL placeholders are $n, SQLite/MySQL ?, named queries use @name.
  Keep SqlDialect compatibility; its strategy adapter is the only enum dispatch.
- Query/model/params/errors must not import drivers. package:postgres imports are
  limited to postgres_connection, session_query_executor, driver_result_mapper
  and postgres_params. Translate concrete driver errors at those boundaries.
- Ambiguous UUID/JSON/decimal values use SqlParam; NULL requires nullOf(SqlType).
  Numeric values remain strings. SQLite needs TEXT affinity; MySQL needs a suitable
  DECIMAL scale for precision. Unsupported non-null time/interval raises a typed error.
- PostgreSQL/SQLite use RETURNING. MySQL uses lastInsertId and reloads by key;
  zero changed rows does not mean missing. Missing reload throws EntityNotFound.
  UUID v4 generation uses const Uuid().v4() only in ReloadWriteStrategy.
- Repository owns validation, hook ordering and clocks. Only individual writes run
  hooks. Bulk insert/upsert skips hooks; built-in MySQL batches use transaction/
  savepoint. Custom executors require TransactionExecutor for atomicity.
- Default update writes changed columns only, no SQL when clean; onlyChanged:false
  forces writing. Loading/writing syncs snapshots; SQL rollback does not rewind them.
- Timestamp/soft-delete metadata is opt-in. Repository.clock supplies timestamps;
  default queries hide trashed rows unless scoped otherwise.
- MySQL upsert matches any unique index; conflictColumns identifies the reload.
  MySQL sessions use UTC, utf8mb4 and strict mode without ANSI_QUOTES. ilike depends
  on collation; sensitive LIKE uses BINARY. SQLite ilike follows ASCII folding and
  rejects sensitive LIKE. Preserve explicit escapes and NULL ordering syntax.
- MySQL diagnostics expose numeric errorCode, not unavailable SQLSTATE. Its query
  timeout discards the connection after ending the wait, not guaranteed server-side
  cancellation. SQLite synchronous statements do not use per-query timeout.
- SQLite Lock is reentrant and per handle; nested transactions use savepoints.
  MySQL statement Lock is non-reentrant; do not wrap the whole transaction in it.
  Reuse pools/handles and explicitly pass transaction executors. No framework adapters.
- Keep public compatibility: writeWord, MysqlConfig.timeZone, MigrationRunner.database
  and the runtime PG binding reexport are deprecated, retained during transition.
  Schema operations use QueryExecutor and TransactionExecutor internally.

## Generation, schema and tests

Generate only lib/generated/tikal.dart; never modify model sources or run generation
inside configure/queries. make:seeder scaffolds application-owned bin/tikal_seed.dart
once; db:seed runs that static entry, propagating its exit code. Its connection is
configured directly by the app, and its finally block closes Tikal. Seeders under
lib/ are validated (constructors, Future<void> run, calls, cycles, duplicate names)
and emitted as tikalSeeders callbacks in the same generated library. Models and
seeders share one semantic analysis session during generation. calls run
sequentially before the parent run; repeated dependencies are not deduplicated.
Its Tikal facade supplies tikalModels and reexports runtime
except the manual Tikal name. Import it at startup; avoid two unprefixed Tikal names.
Manual registry APIs remain compatible. Watch polls every 500 ms, serializes stable
changes, ignores output and preserves the last valid library on errors. init preserves
valid configuration; tikal.json stores paths only. Missing paths are empty only for
generation. Keep imports/constants/typedefs and constructor support in batch analysis.

SchemaTable.createSql, migrations, inspection and schema CLI are PostgreSQL-only,
guarded before SQL. No automatic reconciliation. Preserve checksums, read-only
repeatable-read drift checks and conservative widening. Pagination needs stable
ordering; DISTINCT pagination is rejected. Use repeatable-read for a stable snapshot.

SQLite/pure tests run without services. Server suites require disposable databases:
TIKAL_TEST_DATABASE_URL for PostgreSQL and TIKAL_TEST_MYSQL_URL for MySQL/MariaDB.
They recreate accounts and MySQL uuid_items. Never claim skipped integrations passed;
do not launch MySQL verification without TIKAL_TEST_MYSQL_URL. Generator tests compile
and run the generated entry point. Shared executors live in test/support/executors.dart.

## Change discipline

Use dart-best-practices, design-patterns, orm-performance and postgresql-expert when
relevant. Apply import-organizer to touched Dart imports: external first, then project
imports by path length/alphabetical tie-breaker, responsibility comments following order.
Use Effective Dart, strong typing/null safety, KISS/DRY/YAGNI and pragmatic SOLID.
No public behavior/API change without a test; deprecate before removal. Check usages
before deleting helpers. Do not add unrelated dependencies, files or refactorings.
For phased work, keep one verified commit per phase. Cleanup catches must explain why
preserving an original failure is necessary.

Pending: SQLite/MySQL schema tooling; inherited/transient fields, factory constructors,
duplicate model names, more relationship kinds, joins/grouping/subqueries and cursor
pagination. No implicit lazy loading or schema reconciliation.
