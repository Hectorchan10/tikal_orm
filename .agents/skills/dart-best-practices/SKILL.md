---
name: dart-best-practices
description: "Apply Effective Dart, null safety, strong typing, immutability, and pragmatic SOLID/KISS/DRY/YAGNI when writing or reviewing Dart code, especially in the TikalORM ORM. Use it when designing typed APIs, model classes, F-bounded generics, async error handling, and tests. Includes antipatterns and a verification checklist. For import ordering, apply the import-organizer skill."
---

# Dart Best Practices

Best practices for writing and reviewing idiomatic, high-quality Dart code,
with a focus on designing typed APIs like those in TikalORM.

## 1. Purpose and when to apply

Use this skill when you:

- Write or review Dart code in the `tikalorm/` library.
- Design public typed APIs (models, columns, repositories, builders).
- Introduce generics, class hierarchies, or extension mechanisms.
- Handle asynchrony, errors, and tests.

Do not use it as a justification to refactor working code without a concrete
problem to solve (YAGNI).

## 2. Guiding principles

- **KISS**: the simplest solution that solves the problem. Avoid layers and
  abstractions that add no value today.
- **YAGNI**: don't add parameters, hooks, or generality for hypothetical cases.
- **DRY**: a single source of truth for each rule. Duplicating SQL generation,
  validation, or type-mapping logic is a latent bug. But DRY does not mean
  merging things that change for different reasons.
- **Pragmatic SOLID**:
  - *Single Responsibility*: each file/class does one thing (`SqlWriter` writes
    SQL and binds; `QueryBuilder` composes; `Repository` orchestrates).
  - *Open/Closed*: extend via new implementations of interfaces
    (`QueryExecutor`, `SqlPredicate`) instead of growing conditionals.
  - *Liskov*: every `QueryExecutor` implementation must behave the same inside
    or outside a transaction.
  - *Interface Segregation*: small, specific interfaces
    (`ModelColumnBinding<TModel>` exposes only what the table needs).
  - *Dependency Inversion*: the model and builder depend on the `QueryExecutor`
    abstraction, not on `TikalDatabase` or the `postgres` driver.
- **Measure before optimizing**: don't change things for performance without
  data (see the `orm-performance` skill).

## 3. Strong typing and null safety

- Declare explicit types on public APIs; don't rely on inference at boundaries
  (`strict-inference` is enabled).
- Use **null safety** to model genuine absence. Don't use `late` to dodge
  analysis; use it only when initialization is guaranteed and late.
- Prefer `final` and unmodifiable collections for values that don't change.
  `prefer_final_locals` is enabled.
- Avoid `dynamic` and `Object?` except at boundaries where the type is
  immediately recovered (e.g. row values before decoding). Conversion must
  happen in a single place (`decoders.dart`), not scattered.
- Avoid casts (`as`) outside those controlled conversion points.

```dart
// Good: explicit type at the boundary, centralized decoding.
final total = decodeInt(row, 'total_price');

// Bad: dynamic leaking through the API.
dynamic totalOf(TikalRow row) => row['total_price'];
```

## 4. Type modeling (applied to TikalORM)

- **F-bounded generics** so the model knows its own subtype:

  ```dart
  abstract class TikalModel<T extends TikalModel<T>> { /* ... */ }
  ```

- **`final`/`sealed` classes** when the hierarchy is closed and controlled. In
  Dart, `final` prevents accidental inheritance and enables optimizations.
- **Exhaustive `switch` over enum/sealed**: let the compiler require every case
  instead of a silent `default`.

  ```dart
  final sql = switch (column.sqlType) {
    SqlType.integer => 'integer',
    SqlType.text    => 'text',
    // ... the compiler requires covering the whole enum
  };
  ```

- **Immutable value objects** for `SqlStatement`, `OrderBy`, `SqlParam`: build a
  new value instead of mutating the existing one.

## 5. Immutability and copy-on-write

- An immutable `QueryBuilder` must return a new instance on each step, so a base
  query can be reused without side effects:

  ```dart
  final active = users.where(UserColumns.active.equals(true));
  final byName = await active.orderBy(UserColumns.name).get();
  final newest = await active.orderBy(UserColumns.createdAt, descending: true).get();
  ```

- If you need internal mutable variants for performance, don't expose that
  mutability in the public API.

## 6. Style according to Effective Dart

- Follow the dart.dev guides (style, documentation, usage, design). Key
  examples:
  - Name variables/members in `lowerCamelCase`; types in `UpperCamelCase`.
  - Prefer `final` where applicable.
  - Document (`///`) public APIs; describe *what* and *why*, not *how*.
  - Use single quotes for strings.
  - Prefer typed collection literals: `<String>[]`, `<String, int>{}`.
  - Prefer higher-order functions and `Iterable` over manual loops when it
    improves clarity.
- Don't break project style out of personal preference. `dart format` and
  `dart analyze` are the source of truth.
- For `import`/`export` ordering, apply **import-organizer**, not this skill.

## 7. Asynchrony and error handling

- Use `async`/`await`. Don't leave `Future`s unawaited: `unawaited_futures` is
  enabled; if you truly want to ignore one, use explicit `unawaited(...)`.
- Don't catch errors to swallow them. TikalORM errors have their own taxonomy
  (`TikalException` and subclasses); catch the specific subclass you can handle.
- Convert driver errors into domain errors at the boundary
  (`TikalQueryException.fromServer`), not inside query logic.
- Validate inputs before touching the network (e.g. `TikalValidationException`
  before executing SQL).

```dart
try {
  await user.save();
} on TikalValidationException catch (e) {
  // data error: report to the caller
} on TikalEntityNotFoundException {
  // missing row: decide policy
}
```

## 8. Public API design

- Small, explicit APIs. A method's name should say what it does, and use named
  parameters for configuration booleans:

  ```dart
  builder.orderBy(UserColumns.createdAt, descending: true, nulls: NullsOrder.last);
  ```

- Don't expose driver details (`pg.*`) in the ORM API.
- Programming errors should fail early and clearly (e.g. reject untyped `NULL`);
  don't invent silent default behavior.
- Offer the raw path alongside the typed one: advanced users need direct SQL on
  the same `QueryExecutor`.

## 9. Testing

- One test per observable behavior, not per method.
- Fast unit tests without a database for pure logic (generated SQL, validation,
  decoding). Integration tests against real PostgreSQL for execution semantics.
- Exploit the `QueryExecutor` seam to create test doubles without a database.
- Also verify the generated SQL (`toSql()`), not just the result.
- Name tests describing the expected behavior.

## 10. Antipatterns

- `dynamic` to avoid modeling types.
- Speculative abstractions "just in case" (violates YAGNI).
- Deep inheritance where composition suffices.
- Mutating shared state inside a builder or repository.
- `catch (_) {}` hiding failures.
- Duplicating binding/quoting logic in several places.
- Optimizing without measuring.
- Introducing a pattern (singleton, factory, service locator) without a real
  need.

## 11. References

- Effective Dart: https://dart.dev/effective-dart (style, documentation, usage, design).
- Dart type system: https://dart.dev/language/type-system
- Classes and modifiers (`final`, `sealed`): https://dart.dev/language/classes
- Null safety: https://dart.dev/null-safety
- Recommended lints: https://dart.dev/tools/linter-rules

## 12. Verification checklist

- [ ] Does the public API declare explicit types and respect null safety?
- [ ] Was `dynamic`/`as` avoided outside a controlled conversion point?
- [ ] Is the code immutable where it should be (no shared mutable state)?
- [ ] Was KISS/YAGNI applied: no abstractions for hypothetical cases?
- [ ] DRY: no duplicated SQL, type, or validation logic?
- [ ] Are errors handled by subtype and never swallowed?
- [ ] `dart analyze` clean and `dart format` with no changes?
- [ ] Do tests cover behavior and also the generated SQL?
- [ ] Was import ordering left to import-organizer?
