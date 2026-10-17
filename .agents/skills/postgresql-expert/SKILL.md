---
name: postgresql-expert
description: "Expert PostgreSQL knowledge applied to an ORM: types and their mapping, prepared statements and SQL injection prevention, indexes (B-tree, GIN, partial, INCLUDE), reading EXPLAIN/EXPLAIN ANALYZE, planner statistics, joins, transactions/MVCC and isolation levels, locking, connection pooling, VACUUM/autovacuum, JSONB, keyset pagination, and bulk operations. Includes antipatterns and a checklist."
---

# PostgreSQL Expert

PostgreSQL fundamentals and techniques that a quality ORM must respect and
expose correctly. Primary source: the official PostgreSQL documentation.

## 1. Purpose and when to apply

Use it when you:

- Design the Dart ↔ PostgreSQL type mapping.
- Generate SQL: `WHERE`, `JOIN`, `ORDER BY`, pagination, aggregates.
- Diagnose slowness (EXPLAIN), indexes, or query plans.
- Define transactions, isolation, locking, or pooling.
- Decide how to create indexes and maintain statistics.

## 2. Parameterization and SQL injection

- **Never interpolate values into SQL.** Use *placeholders* (`$1`, `$2`, …) and
  send the values as parameters. The driver and the server handle escaping and
  typing.
- A **prepared statement** separates the plan from the data; it also reduces
  repeated parsing (see `PREPARE` and the extended protocol).
- Table/column names are **not** parameterizable; validate them against an
  allow-list (in TikalORM they come from `ColumnDefinition`/`TableDefinition`,
  not free text) and quote them correctly.
- **NEVER** build SQL like this:

  ```dart
  // DANGEROUS: SQL injection
  final sql = "SELECT * FROM users WHERE email = '$email'";
  ```

  Do this instead:

  ```dart
  // Safe: value as a parameter
  await db.query(
    'SELECT id, email FROM users WHERE email = \$1',
    parameters: [email],
  );
  ```

- When a `String` could map to several types (`uuid`, `jsonb`, `numeric`), type
  the parameter explicitly (`SqlParam.of(SqlType.uuid, value)`), and **require a
  type for `NULL`** (there is no useful untyped `NULL` for the planner).

## 3. Types and mapping

- Choose the right type; changing it later is costly.
  - `text` for text; avoid `varchar(n)` without reason (in PostgreSQL there is
    no performance gain over `text`).
  - `timestamptz` (with zone) for instants; `timestamp` only for "local time".
  - `numeric`/`decimal` for money and exact precision; **never** `float` for
    money. Note: the driver returns `numeric` as `String` to preserve precision;
    convert it carefully.
  - `uuid` for identifiers; `bigint`/`serial`/`bigserial` by volume.
  - Real `boolean`, not `char(1)`.
  - `jsonb` (not `json`) for queryable/indexable documents.
  - PostgreSQL arrays and range types when they add clarity.
- Constraints in the database, not just the app: `NOT NULL`, `UNIQUE`, `CHECK`,
  `FOREIGN KEY`, `PRIMARY KEY`. The app validates for good errors; the database
  guarantees integrity.

## 4. Indexes

- An index speeds up reads and slows down writes; don't index "just in case".
- **B-tree** (default): equality, ranges, and sorting (`=`, `<`, `>`, `BETWEEN`,
  `ORDER BY`).
- **GIN**: JSONB, arrays, full-text search. Example:
  `CREATE INDEX ON users USING gin (profile jsonb_path_ops);`
- **Partial**: index only the relevant subset.
  `CREATE INDEX ON orders (created_at) WHERE status = 'pending';`
- **Covering / INCLUDE**: avoid hitting the table (index-only scan).
  `CREATE INDEX ON users (email) INCLUDE (name);`
- **Expression**: index the result of a function/expression.
  `CREATE INDEX ON users (lower(email));`
- **Composite key**: order matters; equality columns first, and the
  range/sort column last.
- A `UNIQUE` constraint also implements an index; don't duplicate it.
- Align queries with indexes: a `WHERE`/`ORDER BY` without a suitable index
  causes sequential scans.

## 5. EXPLAIN, planner, and statistics

- `EXPLAIN` shows the plan; `EXPLAIN ANALYZE` **executes** it and shows real
  timings and row counts. Use it to diagnose, not in production on expensive
  write queries.
- `EXPLAIN (ANALYZE, BUFFERS)` reveals cache hits/misses.
- The planner is **cost-based** and driven by **statistics**; stale statistics
  produce bad plans. Keep `ANALYZE` running (autovacuum does).
- Warning signs: `Seq Scan` on large tables with a selective filter; row
  estimates far from reality; `Nested Loop` over many rows; disk spill
  (`external merge`).
- Tune planner parameters (`work_mem`, `random_page_cost`, etc.) with judgment
  and measurement, not blindly.
- Low `work_mem` → sorts/hashes spill to disk; raise it per session where
  needed.

## 6. Joins and query shape

- Prefer **explicit JOIN** (`INNER`/`LEFT`) over comma joins with `WHERE`.
- Filter in the `ON` clause of a `LEFT JOIN` so you don't effectively turn it
  into an `INNER`.
- Avoid functions over indexed columns in `WHERE` (`WHERE date(created_at)=…`
  won't use the `created_at` index); rewrite as a range.
- `EXISTS`/`IN` are usually preferable to `DISTINCT` for "there is at least
  one".
- Use the **anti-join** pattern (`LEFT JOIN … WHERE … IS NULL` or `NOT EXISTS`)
  for "does not exist", not `NOT IN` with possible `NULL`s.

## 7. Pagination

- **Large OFFSET is slow**: the server must read and discard all preceding rows.
- Prefer **keyset pagination**: order by a stable key and filter
  `WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC, id DESC LIMIT n`.
- Keysets require a total, stable order (include a unique tiebreaker column).
  Compare it with `LIMIT`/`OFFSET` only for small pages.

## 8. Transactions, MVCC, and isolation

- PostgreSQL uses **MVCC**: readers don't block writers. Each statement sees a
  *snapshot*.
- Isolation levels: `READ COMMITTED` (default), `REPEATABLE READ`,
  `SERIALIZABLE`. Under `REPEATABLE READ`/`SERIALIZABLE`, be ready to retry on
  serialization errors.
- Under `READ COMMITTED`, two statements in the same transaction can see
  different data; if you need consistency, raise isolation or lock.
- **`SELECT … FOR UPDATE`** locks rows to update them safely (avoids *lost
  updates*). Don't use it if you won't write.
- Keep transactions **short**: don't do network I/O or long waits with an open
  transaction (you hold *locks* and *snapshots*).
- Use read-only transactions (`READ ONLY`) for complex reads: avoids write work
  and enables optimizations.
- *Deadlocks* are resolved by the server aborting one transaction; minimize
  their likelihood by accessing tables in a consistent order.

## 9. Connections and pooling

- Each PostgreSQL connection is a **process** with memory cost; don't open one
  per user request.
- Use **pooling**. The optimal size is not "more is better": past the "knee",
  more connections reduce throughput through contention.
- Rule of thumb: size the pool based on the server's cores/IO and transaction
  duration; often a modest pool performs better.
- Configure **connection and query timeouts**; a hung query must not block the
  pool indefinitely.
- Reuse connections and prepared statements; opening/closing per statement
  destroys the benefit.

## 10. Maintenance: VACUUM and autovacuum

- MVCC leaves dead row versions. **VACUUM** reclaims space and freezes tuples;
  **autovacuum** does it automatically.
- Don't disable autovacuum. On high-*churn* tables (updates/deletes), increase
  it.
- `VACUUM FULL` rewrites the table and takes an exclusive lock; use sparingly.
- `ANALYZE` updates planner statistics; run it after bulk loads.
- Monitor bloat and old transactions (*xid wraparound*).

## 11. JSONB

- Use `jsonb` to store and query documents; it's binary, indexable, and
  comparable (text `json` preserves formatting but isn't indexed the same way).
- Index with GIN (`jsonb_path_ops` for `@>` containment).
- Query with operators (`->`, `->>`, `@>`, `?`) or `jsonpath`.
- Don't overuse `jsonb` for data that is clearly relational: you lose
  constraints and types.

## 12. Bulk operations

- Insert in batches (`INSERT … VALUES (…), (…)`) or via `COPY` for large
  volumes; avoid thousands of individual `INSERT`s.
- For *upsert*: `INSERT … ON CONFLICT (key) DO UPDATE SET …`.
- `RETURNING` returns affected rows (e.g. to get generated IDs) without a
  second query.

## 13. Antipatterns

- Interpolating values into SQL (injection).
- `SELECT *` when only a few columns are needed.
- Deep `OFFSET` on large tables.
- Functions over the indexed column in `WHERE`/`JOIN`.
- Indexing everything, or unused indexes that only penalize writes.
- Long transactions with network waits.
- `NOT IN` with nullable columns.
- Disabling autovacuum or ignoring statistics.
- `float` for money.

## 14. References

- JSON types: https://www.postgresql.org/docs/current/datatype-json.html
- Indexes: https://www.postgresql.org/docs/current/indexes.html
- EXPLAIN (command): https://www.postgresql.org/docs/current/sql-explain.html
- Using EXPLAIN: https://www.postgresql.org/docs/current/using-explain.html
- Query planning (planner parameters):
  https://www.postgresql.org/docs/current/runtime-config-query.html
- PREPARE (prepared statements):
  https://www.postgresql.org/docs/current/sql-prepare.html
- Concurrency control / MVCC: https://www.postgresql.org/docs/current/mvcc.html
- Transaction isolation:
  https://www.postgresql.org/docs/current/transaction-iso.html
- Routine vacuuming:
  https://www.postgresql.org/docs/current/routine-vacuuming.html
- Explicit joins: https://www.postgresql.org/docs/current/explicit-joins.html
- Performance tips:
  https://www.postgresql.org/docs/current/performance-tips.html
- Number of connections (wiki):
  https://wiki.postgresql.org/wiki/Number_Of_Database_Connections

## 15. Verification checklist

- [ ] Do all values travel as parameters, never interpolated?
- [ ] Are the chosen types correct (`numeric` for money, `timestamptz` for
      instants, `jsonb` for documents)?
- [ ] Do indexes align with the real `WHERE`/`ORDER BY`/`JOIN` patterns?
- [ ] Was the plan read with `EXPLAIN (ANALYZE, BUFFERS)` before optimizing?
- [ ] Is deep `OFFSET` avoided (keyset where appropriate)?
- [ ] Are transactions short and at the right isolation level?
- [ ] Is the pool sized with timeouts?
- [ ] Are autovacuum/ANALYZE healthy?
- [ ] Do bulk operations use batches/`COPY`/`ON CONFLICT`?
