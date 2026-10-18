# AGENTS.md

English code/dartdoc. Focused changes, KISS/DRY/YAGNI, pragmatic SOLID.
Read [the complete invariant inventory](docs/invariants.md) before editing runtime,
generator, schema or driver behavior. Its rules remain mandatory.

## Operational rules

- One package `tikal_orm`, Dart ^3.13.5; version 0.2.0 in pubspec and
  tikalOrmVersion stays synchronized. No packages/workspaces or new dependencies.
- No reflection, runtime generation, compatibility-only APIs or import effects.
- Every public member has dartdoc. Every generator source stays below 300 lines.
- Use dart-best-practices, design-patterns, orm-performance and postgresql-expert
  when relevant. Apply import-organizer: external imports first, then project
  imports by full URI length and alphabetical tie-breaker; responsibility comments.
- Keep query/model/errors and portable parameters free of driver imports.
  Analyzer/path imports never enter runtime. See the exact boundaries in the inventory.
- Generate before consuming-app builds; never during configure or queries.
  Preserve application-owned entry points, manual constructors and concurrent edits.
- Configure and queries never create/reconcile schema. Explicit DDL requires existing
  schemas/databases; migrations/inspection/schema CLI remain PostgreSQL-only.
- Main access is Tikal.model<T>(); explicit executors win over Zone, then pool.
  Await all transaction work inside callbacks; snapshots do not rewind on rollback.
- Only withRelations reads related tables; only attach/detach/sync/toggle writes
  join rows. No implicit lazy load, collection flush or entity cascades.
- Inspect usages before deletion. Behavioral changes require regression tests;
  breaking changes require changelog migration notes. Cleanup catches explain why
  preserving the original outcome matters. Do not refactor outside the task.
- Do not commit or upload when work is requested locally.

## Layout and checks

See [layout](docs/internal-layout.md), [invariants](docs/invariants.md), and
[documentation](docs/index.md) for the complete inventory of existing rules.

```sh
dart pub get
dart format .
dart analyze
dart test
dart pub publish --dry-run
dart run tikal_orm:tikal generate # In a consuming application.
```

Format must be a no-op, analysis clean and tests green. Never claim omitted tests
passed. SQLite/pure tests need no services. Server suites require disposable
TIKAL_TEST_DATABASE_URL / TIKAL_TEST_MYSQL_URL; never run MySQL tests without its URL.
See the inventory for recreated table names. Generator tests execute consumer
programs and AOT bundles. PostgreSQL close tests use a local TCP stub only.
