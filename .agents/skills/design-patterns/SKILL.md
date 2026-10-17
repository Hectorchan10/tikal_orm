---
name: design-patterns
description: "Design patterns applicable to an ORM (Repository, Data Mapper, Active Record, Unit of Work, Query Object/Specification, Builder, Identity Map, Adapter, Strategy, Factory) explained pragmatically and mapped to TikalORM, using SQLAlchemy/SQLModel, Hibernate/JPA, and Eloquent as references. Includes when NOT to use each pattern (YAGNI) and a verification checklist."
---

# Design Patterns (ORM Design)

Design patterns useful for building and evolving TikalORM, plus the rationale
for when **not** to apply them. The references are mature ORMs
(SQLAlchemy/SQLModel, Hibernate/JPA, Eloquent) and the SOLID, KISS, DRY, and
YAGNI principles.

## 1. Purpose and when to apply

Use it when you:

- Decide how to model data access (repositories, mapping, sessions).
- Evaluate introducing a new pattern into the ORM.
- Review a design for over-engineering or coupling.

Don't use it to add patterns "for completeness". A pattern that doesn't solve a
present problem is cost without benefit.

## 2. The patterns and their place in TikalORM

### 2.1 Adapter — the driver as a detail

Isolate the `postgres` driver behind your own interface (`QueryExecutor`). The
rest of the system doesn't know `pg.*`. This lets you swap drivers or simulate
the database in tests without touching models or the builder.

- **When to use**: whenever there's an external dependency (driver, network).
- **Antipattern**: leaking driver types (`pg.Result`, `pg.TypedValue`) into the
  public API.

### 2.2 Strategy — type and SQL mapping per case

Each `SqlType` knows how to represent itself; each `SqlPredicate` knows how to
write its fragment. Adding a type or an operator is adding an implementation,
not modifying a giant `switch` scattered across the code.

- **When to use**: when an algorithm varies by type/case and the variants grow
  (PostgreSQL types, comparison operators, ordering with NULLs).
- **Antipattern**: cascading `if/else` on column type in multiple places.

### 2.3 Data Mapper vs Active Record

- **Data Mapper**: separates the domain object from its persistence.
  `Repository` + `TableDefinition` + decoders fill this role: the entity knows
  no SQL.
- **Active Record**: the model knows its own persistence (`user.save()`).
- **Recommendation in TikalORM**: keep the **Data Mapper** as the base layer
  (testable, decoupled) and offer Active Record style as a *thin facade* on top
  (`User.find(id)`, `user.save()`), without duplicating logic. The facade
  delegates to the repository; it does not reimplement SQL.
- **Antipattern**: mixing both at the same level and having two write paths with
  different rules.

### 2.4 Repository

Encapsulates access to an aggregate (`Repository<User>`) and exposes
domain-oriented operations (find, insert, update, delete, query). Hides SQL and
table details.

- **When to use**: for each aggregate root with persistence.
- **Avoid**: giant generic repositories with dozens of speculative methods; add
  operations when needed.

### 2.5 Query Object / Specification

Represents a query as a value (`QueryBuilder`, `SqlPredicate`). Lets you compose
and reuse conditions, and test the query without executing it.

```dart
final adults = UserColumns.age.greaterThanOrEqual(18);
final active = UserColumns.active.equals(true);
final visible = adults.and(active); // composition of specifications
```

- **When to use**: when conditions are combined and reused.
- **Antipattern**: hand-building and concatenating SQL strings.

### 2.6 Builder — step-by-step queries

A fluent, immutable builder that grows clause by clause (`where`, `orderBy`,
`limit`) and is materialized at the end (`get`, `first`, `count`).

- **When to use**: readable query APIs; step-by-step construction.
- **Rule**: immutable (each method returns a new builder) so a base can be
  reused without side effects.
- **Antipattern**: a mutable builder shared across async execution paths.

### 2.7 Unit of Work and transactions

Groups changes to commit or roll back as a single operation. In TikalORM it is
expressed through the transaction/session (a scoped `QueryExecutor`).

- **When to use**: multiple writes that must be atomic.
- **Rule**: the transaction scope is explicit and short; don't leave
  transactions open during network or UI work.
- **Antipattern**: business logic assuming auto-commit, an implicit global
  transaction, or nested transactions without savepoints.

### 2.8 Identity Map

Guarantees a single instance per row within a session. It's optional and
costly; only add it if it avoids real work (repeated reads).

- **When to use**: if within a session/transaction the same rows are loaded
  repeatedly and shared identity matters.
- **YAGNI**: don't implement it by default without a measured case.

### 2.9 Lazy vs Eager loading

Explicitly decide when relationships load.

- **Lazy**: convenient but prone to N+1 (see the `orm-performance` skill).
- **Eager**: load with `JOIN`/`IN` when you know you'll need the relationship.
- **Recommendation**: prefer explicit loading; avoid "magical" lazy loads that
  fire hidden queries.

### 2.10 Factory

Builds complex instances. In TikalORM, `TableDefinition.newInstance` is a
factory that rebuilds a model from a row. Use it to centralize construction;
not to hide dependencies.

### 2.11 Facade

A simple interface over a subsystem. The Eloquent-style facade
(`User.find`, `User.all`) is a facade over repository + builder. It must be thin
and delegate.

## 3. Composition principles

- Prefer **composition over inheritance**. Inheritance is reserved for closed
  hierarchies (e.g. `SqlPredicate`).
- **Dependency inversion**: depend on `QueryExecutor`, not the concrete
  database.
- **Value immutability**: `SqlStatement`, `OrderBy`, `SqlParam` are built, not
  mutated.
- **Clear boundaries**: the query layer doesn't depend on the model (it uses
  `ColumnDefinition`), avoiding import cycles.

## 4. Antipatterns (what to avoid)

- **Singleton** for the database: couples and hinders testing. Inject the
  executor.
- **Service Locator**: hidden dependencies. Prefer explicit injection.
- **God Object**: a `Repository` or `Database` that does everything.
- **Anemic + Active Record mixed** with divergent rules.
- **Speculative abstraction**: generalizing for a dialect/case that doesn't
  exist.
- **Magic reflection**: Dart has no runtime reflection under AOT; don't design
  assuming dynamic table discovery. Prefer explicit metadata
  (`TableDefinition`) or code generation.
- **Implicit global transaction**: make the transaction scope explicit.

## 5. References

- SQLAlchemy ORM — Session basics (Unit of Work, Identity Map):
  https://docs.sqlalchemy.org/en/20/orm/session_basics.html
- SQLModel (Data Model + typing):
  https://sqlmodel.tiangolo.com/
- Spring Data JPA — query methods (Repository):
  https://docs.spring.io/spring-data/jpa/reference/jpa/query-methods.html
- Laravel Eloquent (Active Record, models):
  https://laravel.com/docs/12.x/eloquent
- Effective Dart (design, style):
  https://dart.dev/effective-dart

## 6. Verification checklist

- [ ] Each applied pattern solves a **present** problem, not a hypothetical one.
- [ ] The domain doesn't leak driver types (`pg.*`).
- [ ] Repository and builder don't duplicate logic (DRY).
- [ ] Specifications/conditions compose as reusable values.
- [ ] Builders and value objects are immutable.
- [ ] No singleton/locator hiding dependencies.
- [ ] Transaction scopes are explicit and short.
- [ ] Composition was preferred over inheritance, with closed hierarchies where
      appropriate.
- [ ] The Active Record style, if present, is a thin facade over Data Mapper.
