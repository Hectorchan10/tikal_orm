# Changelog

All notable changes to TikalORM will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/).

## 0.2.0

### Audit migration notes

- createTables(allowExistingSchemas: true) opts into existing PostgreSQL schemas
  only, verifying every referenced namespace before DDL; defaults stay conservative.
- Seeder syntax discovery reduces semantic roots without losing const aliases;
  watch caches hashes with event invalidation and periodic content reconciliation.
- Unexpected driver errors are now safe TikalQueryException wrappers; inspect cause
  explicitly instead of catching the original untyped driver/programming error.

- Query exception strings and redactedDiagnostics now expose only concrete error
  category and allowlisted codes. Read sql/serverMessage/detail/hint/parameters/cause
  explicitly for sensitive debugging; do not serialize the complete exception.
- ForeignKey emits column/constraint metadata only. Replace User_.roleIdRelation
  with @BelongsTo(Role, foreignKey: 'roleId') Role? role and User_.roleRelation.
- Raw predicates lex strings, identifiers, comments and PG dollar quotes. Use ??
  for a literal question mark / PostgreSQL lone ? operator; ?,? still binds two
  values. PostgreSQL ?|, ?& and @? operators remain literal. Values are never interpolated.

### Added

- Nullable @BelongsTo/@OneToOne object fields emit explicit batch loaders and
  loaded-result accessors. OneToOne requires a unique target foreign key and
  rejects multiple matches; soft-deleted targets are excluded.

- Generated `loaded.permissionsFor(model)` collection accessors reuse explicitly
  loaded relation maps and never execute additional queries.

### Breaking

- Generator rejects composite primary keys on application models rather than
  emitting mappings that fail later. Use one surrogate `@PrimaryKey()` plus
  `@UniqueConstraint(name: 'uq_edge', columns: ['sourceId', 'targetId'])` where
  appropriate. Internal ManyToMany bridges retain composite keys. Bridge payload
  models requiring composite identity remain pending.

- Acronyms now infer snake_case without a leading underscore: `userID` becomes
  `user_id`, `HTTPCode` becomes `http_code`, `parseHTMLString` becomes
  `parse_html_string`. Existing database columns are not renamed automatically.
  Preserve an old name with `@Column(name: 'user_i_d') int userID;`, or write a
  reviewed rename migration before deploying regenerated mappings. Implicit join
  columns also lose their old leading underscore; pin joinColumn and
  inverseJoinColumn explicitly to preserve existing bridge schemas.
- Index/UniqueConstraint columns now name Dart fields, never SQL names:
  `@Index(name: 'idx_user', columns: ['userID'])` resolves the field's SQL mapping.
  Change `columns: ['user_id']` to `columns: ['userID']`. Snapshot JSON still stores
  SQL names and its format is unchanged; no SQL-name compatibility fallback remains.

- Ordering and aggregates require columns of the queried model. Bulk updates now
  take typed assignments: `.update([User_.name.assign('Ana')])` replaces
  `.update({User_.name: 'Ana'})`. Values are encoded only during execution.
- Invalid repository primary-key types fail before SQL with table/column diagnostics.
  Custom `ModelColumnBinding` implementations must implement `acceptsValue` to
  validate Dart values; standard ModelColumn bindings provide it automatically.
- Replace the runtime static facade with `TikalClient(models: registry)`. Generated
  application entries expose one `Tikal` client; importing the runtime together
  with the generated entry no longer needs `hide Tikal`.
- Remove global CRUD shortcuts and generated per-model CRUD/repository helpers.
  Migrate `Tikal.save(user)` / `User_.save(user)` to
  `Tikal.model<User>().save(user)`, `find` to `findById`, `all` to `findAll`,
  and `Tikal.query<User>()` to `Tikal.model<User>().query()`.
  Migrate `User_.create(user)` to `Tikal.model<User>().insert(user)` and
  `User_.delete(user)` to `Tikal.model<User>().delete(user)`.
  Tools can construct `Repository(executor: db, definition: User_.table)`.

### Fixed

- Join target key validation now precedes source locking, with no SQL for invalid keys.
- Duplicate bulk assignments now throw ArgumentError before SQL; pass each SQL
  column once: `.update([User_.name.assign('Ana')])`.
- Explicit createTables rejects unsupported schemas before DDL. Provision schemas
  separately and use reviewed DDL; SQLite continues ignoring schema names.
- CLI dispatch, generation/diff and migration execution are separated without
  changing command behavior or output.
- Seeder runners import the consuming package by its pubspec name.
- Query errors retain sensitive parameters for explicit diagnosis; log only
  `error.redactedDiagnostics()` (SQL literals can still contain secrets).

- Client transactions scope implicit model access through async Zones; nested
  calls use savepoints and explicit executors retain priority. Acquire repositories
  inside the callback instead of capturing a repository bound to the pool. Await
  all work inside the callback; late inherited access now fails after completion.
  Model snapshots still do not rewind on rollback.

## 0.1.1

### Added

- Explicit dialect-aware table/index creation helpers and opt-in Tikal.createTables
  for development/tests, including constraints, join tables and runtime DbType
  overrides. Snapshot JSON, checksums and PostgreSQL migration behavior are unchanged.
  Manual registries need schema metadata; regenerate existing application mappings.

- Typed UNIQUE/primary-key, FOREIGN KEY and NOT NULL query violations across
  PostgreSQL, MySQL/MariaDB and SQLite, preserving original diagnostics.
  SQLite query errors now include the extended result code in errorCode.

- Repeatable @Index and @UniqueConstraint annotations using ordered SQL columns,
  static validation, PostgreSQL DDL/diff/catalog inspection and migration safety flags.

- VS Code/Cursor folder-open generation tasks scaffolded by init, using the existing
  watcher and preserving existing editor tasks and permissions.

- Automatic named constructors for annotated models without constructors, with
  nullable/required fields and defaults inferred statically. Generated constructors
  update after field changes; manual constructors and mutable relation defaults stay
  intact. Model source writes occur only after generation validation and formatting.

- Generation scaffolds application-owned lib/tikal.dart once so startup and new
  seeder runners import the application entry instead of generated mappings directly.
  Existing entry files are preserved; mapping regeneration remains static.

- Portable double, Uint8List, JSON and exact decimal mappings, per-dialect type
  capabilities and early unsupported-column validation.
- Const TypeConverter/@Convert, @Enumerated name/ordinal mappings, built-in
  Duration/Uri/BigInt/JSON-object converters and opt-in @DbType declarations.
- PostgreSQL inet/array converters and array/JSON-path predicates; MySQL YEAR/SET
  converters. PostgreSQL's public entry exports native converter contracts.
- Explicit @ManyToMany/@HasMany metadata, generated loaders and owner-only join
  handles with transactional, bounded attach/detach/sync/toggle operations.
- Composite primary-key schema metadata and explicit foreign-key actions;
  generated tikalSchema includes each model-less bridge with cascading keys.
- @Version optimistic locking with atomic counters, conditional writes and typed
  missing-or-concurrent outcomes, including individual soft deletes/restores.
- Connection-scoped query listeners with duration/success events, explicit removal,
  session/transaction propagation and isolated callback failures.
- Static-generation, converter, relation, SQL, concurrency and AOT verification.

### Fixed

- insertAll/upsert respect parameter limits and roll back all batches together,
  including decoder failures; model values/snapshots publish only after success.
- Successful dialect validation runs once per immutable table definition/dialect.
- Bulk writes reject ordering, pagination and DISTINCT clauses before SQL.
- Timestamp writes and snapshots normalize UTC before encoding; bulk updates stamp
  omitted updated-at values and soft deletes share one configured clock stamp.
- MySQL write/reload uses available transactions and reuses active transactions.
- save inserts new assigned-key instances and updates persisted snapshots.
- Encoded, deep JSON snapshots detect nested changes without requiring domain ==.
- Raw predicates retain grouping in soft-delete and combined filters.
- Literal text helpers support SQLite's ASCII-insensitive matching; generated text
  fields expose TextColumn helpers. Explicit sensitive LIKE remains unsupported.
- PostgreSQL close waits for pending initialization; SQLite/MySQL share client UUID
  preparation while PostgreSQL retains server defaults.
- Relation examples use independent mutable lists without implicit persistence.
- ModelColumn rejects simultaneous encode and converter arguments.

### Changed

- Breaking: physical delete(model) checks the original @Version snapshot and throws
  TikalConcurrencyException for stale/missing rows. forceDelete remains unchecked;
  soft deletion, restore and key-only deletion semantics are unchanged.
- Bulk operations now require TransactionExecutor, including custom executors.
  Bulk preparation leaves input timestamps/UUIDs untouched; use returned models
  for generated values. TableDefinition copies and freezes its column list.
- Keep one package with database drivers/helpers, SQL parameters/native support,
  model metadata/conversion/relations and generator analysis/emission subfolders.
  Dialects are engine-specific parts of one shared strategy library.
- Public entry points and CLI commands remain unchanged. Analyzer stays a resolved
  dependency but does not enter the runtime import graph.
- TableDefinition owns default ModelState and is no longer const. Snapshots store
  encoded SQL values. Tikal.model returns Repository directly.
- Existing primary-key changes require reviewed manual migrations.
- README provides a quick start; docs/internal-layout.md describes source boundaries.
- Enable strict casts/inference/raw types and English public API dartdoc.

### Removed

- Legacy TikalModel, dual trackers, ModelAccess and legacy generation/cleanup paths.
- DialectExecutor/dialectOf fallback; custom executors declare their dialect.
- Repository.create alias and generated configure registry overrides.
- SqlWriter.writeWord; use write with explicit spacing.
- MysqlConfig.timeZone options; sessions remain UTC and URL/environment timezone
  aliases accept only +00:00.
- MigrationRunner.database; use executor.
- Runtime PostgreSQL binding reexports and PostgresSqlParamBinding.toDriverValue;
  import explicit binding functions from package:tikal_orm/postgres.dart.

### Migrating from 0.1.0

Use forceDelete for intentional physical deletion without optimistic checks.
Implement TransactionExecutor on custom executors used for bulk writes, and stop
mutating TableDefinition.columns after construction. Regenerate to include indexes;
existing snapshot JSON/checksums without indexes remain unchanged.

Use plain annotated classes and regenerate the single entry point. Remove obsolete
part files manually. Update internal imports and custom executor dialect getters.
Use write, migration executor, UTC-only MySQL settings and explicit PostgreSQL
bindings. Use loaded models for updates or upsert for deliberate conflict merging.
Relation lists do not persist themselves; use their explicit handles. Bulk writes
and upserts cannot bypass optimistic version checks on versioned tables.

## [0.1.0] - 2026-10-16

### Added

- Initial experimental release of TikalORM.
- Support for PostgreSQL, MySQL/MariaDB, and SQLite.
- Annotation-based model definitions and field mapping.
- Static code generation with automatic model registration.
- Type-safe Query Builder with filtering, sorting, and pagination.
- CRUD operations through repositories and the Tikal facade.
- Model change tracking and partial updates.
- Primary keys, unique constraints, and relationship metadata.
- Database transactions and nested savepoints.
- Optional timestamps and soft deletes.
- PostgreSQL schema inspection, migrations, and schema diffing.
- Migration history verification and rollback support.
- Annotation-based database seeders with dependency execution.
- CLI commands for initialization, generation, migrations, and seeders.
- Automatic code regeneration with watch mode.
- Connection pooling for PostgreSQL and MySQL.
- Typed exceptions and database error handling.
- Parameterized SQL queries for safer database operations.

### Notes

- This is an experimental release. Public APIs may change before version 1.0.0.
- Schema inspection and migrations currently support PostgreSQL only.
- SQLite and MySQL/MariaDB support database operations but not schema migrations.
- Code generation must be executed before using generated model helpers.
- Database tables are not automatically created during connection configuration.
