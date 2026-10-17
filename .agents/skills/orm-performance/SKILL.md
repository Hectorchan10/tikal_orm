---
name: orm-performance
description: "Measure-driven performance practices for an ORM: detecting and fixing N+1 queries, eager loading via JOIN/IN, column projection, keyset pagination, batching/bulk insert and upsert, prepared-statement reuse, connection-pool sizing, query logging with EXPLAIN ANALYZE, benchmarking methodology, and safe caching. Includes Dart-specific notes (no runtime reflection; codegen) and antipatterns relevant to TikalORM."
---

# ORM Performance

How to find and fix performance problems in an ORM-backed application, always
from **measurement**, never from intuition. Complements the `postgresql-expert`
skill (database side) and `design-patterns` (architecture side).

## 1. Purpose and when to apply

Use it when you:

- Notice slow endpoints, high query counts, or memory growth.
- Add or review data-access code that reads/writes many rows.
- Decide between eager loading, projection, batching, or caching.
- Benchmark the ORM fairly.

**Golden rule**: measure → identify the bottleneck → change one thing →
measure again. Optimizing without measurement is guessing.

## 2. The N+1 query problem

The single most common ORM performance bug.

- **Symptom**: one query to fetch `N` parents, then `N` more queries (one per
  parent) to fetch a relationship. Total: `N + 1` round trips.
- **Detection**: log every statement and count queries per request; a count
  that grows with the result-set size is the tell. Also look for repeated
  identical SQL differing only in an id parameter.

  ```dart
  // Antipattern: N+1
  final orders = await Order.query(db).get();
  for (final order in orders) {
    // fires one query per order
    final customer = await Customer.query(db)
        .where(CustomerColumns.id.equals(order.customerId))
        .first();
  }
  ```

- **Fixes** (prefer in this order):
  1. **Join / explicit eager load** for the rows you actually need.
  2. **`WHERE … IN (…)` batch load**: collect the parent ids, load all children
     in one query, group in memory.
  3. **A single joined projection** when only a few child columns are needed.

  ```dart
  // Batch load: one extra query total, not N.
  final ids = orders.map((o) => o.customerId).toSet();
  final customers = await Customer.query(db)
      .where(CustomerColumns.id.isIn(ids))
      .get();
  ```

- **Rule**: never let a query inside a loop depend on the loop's iteration
  count. Hoist it out.

## 3. Lazy vs eager loading

- Lazy loading hides queries; it's a footgun for anything that iterates.
- Make relationship loading **explicit**. When you know you need the related
  data, load it in the same round trip or in a single batch.
- Don't eagerly load relationships you won't use: that's over-fetching.

## 4. Projection: select only what you need

- Avoid `SELECT *` when a subset of columns suffices. Less data over the wire,
  less decoding, more chances of an index-only scan.
- For list endpoints, select the columns the UI shows; fetch the full row only
  for detail views.
- Beware of wide `text`/`jsonb` columns in list queries.

## 5. Pagination

- Never return unbounded result sets. Always paginate lists.
- **Small pages**: `LIMIT`/`OFFSET` is fine.
- **Deep pages / large tables**: use **keyset pagination** (see
  `postgresql-expert`). Steady cost regardless of depth.
- Count queries (`COUNT(*)`) on huge tables are expensive; consider approximate
  counts or avoiding a total when the UI doesn't need it.

## 6. Writing data efficiently

- **Batch inserts**: a multi-row `INSERT … VALUES (…), (…)` or `COPY`, not one
  insert per row. Generate one placeholder per value so it stays parameterized.

  ```dart
  // One round trip for many rows: multi-row INSERT with generated placeholders.
  final placeholders = <String>[];
  final params = <Object?>[];
  for (var i = 0; i < tags.length; i++) {
    placeholders.add('(\$${i * 2 + 1}, \$${i * 2 + 2})');
    params.addAll(<Object?>[tags[i].name, tags[i].active]);
  }
  await db.execute(
    'INSERT INTO tags (name, active) VALUES ${placeholders.join(', ')}',
    parameters: params,
  );
  ```

- **Upsert** with `INSERT … ON CONFLICT … DO UPDATE` instead of read-then-write.
- **`RETURNING`** to get generated ids/values without a follow-up `SELECT`.
- **Bulk update/delete** by predicate instead of loading rows and saving each
  one (but remember: bulk operations bypass per-model validation by design;
  validate the predicate/inputs explicitly).
- Wrap multi-statement writes in a transaction: fewer round trips and atomicity.
- Keep transactions short for concurrency (see `postgresql-expert`).

## 7. Statements and prepared-plan reuse

- Reuse the same SQL text with different parameters so the server can cache the
  plan (generic plan) and skip re-parsing.
- Parameterize everything (this is also the SQL-injection defense).
- When a plan regresses after reuse (plan-cache pitfalls), consider `PREPARE`
  explicitly or forcing a custom plan for that statement.
- Don't build SQL strings dynamically per call; that defeats plan reuse.

## 8. Connections and pooling

- Use a pool; opening a connection per request is the classic killer.
- Size the pool deliberately (cores/IO, transaction duration); past the knee,
  more connections *reduce* throughput.
- Set connection and query **timeouts** so a stuck query doesn't exhaust the
  pool.
- Don't hold a connection (or transaction) idle during unrelated work.

## 9. Caching (with discipline)

- The cheapest query is the one you don't run. But cache only when measured.
- **Identity map**: within one session/transaction, avoid re-fetching the same
  row. Optional; add it only with a proven case.
- **Application cache**: for hot, rarely-changing reads. You own invalidation;
  a wrong cache is worse than no cache.
- **Second-level cache**: powerful but complex; introduce it consciously (YAGNI
  until proven).
- Never cache across security boundaries (per-user data) without keying by user.

## 10. Measurement and benchmarking

- **Instrument**: log SQL with durations; count queries per request. Add a
  query counter in development.
- **Profile the database**: `EXPLAIN (ANALYZE, BUFFERS)` for individual slow
  queries; `pg_stat_statements` for aggregate hot spots.
- **Benchmark honestly**:
  - Use realistic data volumes and distributions (an empty table hides
    sequential scans).
  - Warm up, then run enough iterations and report median/p95, not a single
    run.
  - Change one variable at a time.
  - Measure end-to-end (query count + latency), not just CPU.
- **Avoid micro-optimizing Dart object allocation before fixing query count**:
  round trips usually dominate.
- Keep a regression baseline (e.g. query count per endpoint) so new N+1s are
  caught.

## 11. Dart-specific notes

- **No runtime reflection under AOT**: don't design for dynamic discovery of
  tables/columns; performance and correctness favor explicit metadata or
  **code generation** (`User_` style) to avoid per-call map lookups.
- Prefer **explicit typed columns** over string keys for decoded access; the
  decoding path runs per row and per column.
- Reuse immutable query builders instead of rebuilding the same base query.
- Avoid `dynamic` in hot paths; it defeats AOT optimizations.
- Favor batch APIs over per-row async calls to reduce `Future`/microtask
  overhead and round trips.

## 12. Antipatterns

- Any query inside a loop whose count depends on the result size (N+1).
- `SELECT *` on wide tables for list views.
- Unbounded queries (no `LIMIT`).
- Deep `OFFSET` on large tables.
- One `INSERT`/`UPDATE` per row for bulk work.
- Opening a connection/transaction per statement.
- Caching before measuring, or caching without invalidation.
- Optimizing Dart allocations while N+1 remains.
- Adding a second-level cache/identity map "just in case" (YAGNI).

## 13. References

- Using EXPLAIN: https://www.postgresql.org/docs/current/using-explain.html
- EXPLAIN (command): https://www.postgresql.org/docs/current/sql-explain.html
- Performance tips:
  https://www.postgresql.org/docs/current/performance-tips.html
- PREPARE (plan reuse): https://www.postgresql.org/docs/current/sql-prepare.html
- Query planning config:
  https://www.postgresql.org/docs/current/runtime-config-query.html
- Number of connections (pooling, wiki):
  https://wiki.postgresql.org/wiki/Number_Of_Database_Connections
- SQLAlchemy ORM — Session basics (identity map, unit of work):
  https://docs.sqlalchemy.org/en/20/orm/session_basics.html
- Laravel Eloquent (chunking, cursors, eager loading):
  https://laravel.com/docs/12.x/eloquent
- Spring Data JPA — query methods:
  https://docs.spring.io/spring-data/jpa/reference/jpa/query-methods.html

## 14. Verification checklist

- [ ] Is the query count per request independent of result-set size (no N+1)?
- [ ] Do list queries select only needed columns and always have a `LIMIT`?
- [ ] Is deep pagination done by keyset, not large `OFFSET`?
- [ ] Are bulk writes batched (multi-row `INSERT`/`COPY`/`ON CONFLICT`)?
- [ ] Are prepared statements reused with parameters (no dynamic SQL per call)?
- [ ] Is the connection pool sized with timeouts, and are transactions short?
- [ ] Was the bottleneck confirmed with EXPLAIN ANALYZE / query logging?
- [ ] Was each optimization measured before and after?
- [ ] Is caching only present where a measured need justifies it, with
      invalidation?
