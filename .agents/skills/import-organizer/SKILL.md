---
name: import-organizer
description: "Organizes imports exclusively in Dart and Flutter without modifying application logic. Automatically detects the project's package name, places external libraries first, and sorts all project imports by ascending path length, using alphabetical order as a tiebreaker. Adds short comments based on responsibility."
---

# Dart Import Organizer

Organize only import declarations in `.dart` files.

## 1. Main Rules

1. Modify only the import section.
2. Never modify code outside the import section.
3. Never add, remove, or modify imports.
4. Place external libraries first, without comments.
5. Place all project-owned imports after external imports.
6. Sort each group by total path length, from shortest to longest.
7. Break ties between paths of equal length alphabetically.
8. Keep all project-owned imports together without prioritizing folders or modules.
9. Add simple comments based on the responsibility of each project-owned import.
10. Group consecutive imports that share the same responsibility.
11. Never move imports solely to create groups.
12. Ensure deterministic and idempotent results.

## 2. Project Detection

Read `pubspec.yaml` to identify the package name.

Example:

```yaml
name: tikal_orm
```

### External Imports

The following are considered external:

- `dart:`
- `package:flutter/`
- `package:postgres/`
- Any `package:` import whose package name does not match the current project.

Do not add comments to external imports.

### Project-Owned Imports

The following are considered project-owned:

- Relative paths such as `../model/user.dart`.
- Relative paths such as `./config.dart`.
- `package:` imports whose package name matches the name declared in `pubspec.yaml`.

Never hardcode package names.

## 3. Required Import Order

```text
EXTERNAL IMPORTS
       ↓
SORT BY ASCENDING PATH LENGTH
       ↓
PROJECT-OWNED IMPORTS
       ↓
SORT BY ASCENDING PATH LENGTH
       ↓
ALPHABETICAL TIEBREAKER
       ↓
RESPONSIBILITY COMMENTS
```

Calculate path length using the complete import URI, including `package:`, `dart:`, and relative path prefixes.

Do not include quotation marks, keywords, semicolons, or modifiers in the length calculation.

Example:

```dart
import 'dart:async';
import 'package:postgres/postgres.dart';

// Model
import '../model/user.dart';

// Config
import '../config/sql_type.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_result.dart';
```

## 4. Responsibility Comments

Identify each import's responsibility using its filename or semantic directory.

Common comments:

- `// Api`
- `// Auth`
- `// Config`
- `// Const`
- `// Controller`
- `// Database`
- `// Errors`
- `// Executor`
- `// Home`
- `// Model`
- `// Params`
- `// Query`
- `// Repository`
- `// Routes`
- `// Service`
- `// Storage`
- `// Themes`
- `// Utils`
- `// Widget`

Use simple names that are consistent with the project's conventions.

### Special Rules

- `*_routes.dart` → `Routes` when the file is a route aggregator.
- `*_model.dart` → `Model`.
- `*_service.dart` → `Service`.
- `*_repository.dart` → `Repository`.
- `*_controller.dart` → `Controller`.
- `*_config.dart` → `Config`.

Do not create unnecessary comments or use comments to influence import ordering.

## 5. Grouping

When multiple consecutive imports share the same responsibility, use a single comment.

```dart
// Model
import '../model/role.dart';
import '../model/user.dart';
```

If the same responsibility appears again after another group, repeat its comment.

```dart
// Model
import '../model/user.dart';

// Config
import '../config/sql_type.dart';

// Model
import '../features/auth/model/session_model.dart';
```

Grouping must never take priority over path length.

## 6. Preserve Syntax

Preserve the following exactly:

- `as`
- `show`
- `hide`
- `deferred`
- Conditional imports
- Original import paths
- Original aliases
- Special directives

Never convert relative imports into `package:` imports or vice versa.

Do not modify `export`, `part`, or `part of` declarations.

Do not reorder imports that depend on special directives if doing so could change their behavior.

## 7. Spacing

- Do not add comments to external imports.
- Separate external and project-owned imports with one blank line.
- Separate responsibility groups with one blank line.
- Do not separate consecutive imports belonging to the same group.
- Do not duplicate comments.
- Do not leave empty responsibility comments.

Maintain syntax compatible with `dart format`.

Do not run formatters on the entire file if they could modify code outside the import section.

## 8. Strict Restrictions

The following actions are prohibited:

1. Modifying classes, methods, or functions.
2. Modifying constructors or properties.
3. Modifying business logic.
4. Adding or removing dependencies.
5. Removing unused imports.
6. Adding missing imports.
7. Changing import paths or aliases.
8. Renaming files.
9. Creating additional classes or files.
10. Modifying code outside the import section.
11. Creating unnecessary abstractions.
12. Changing the file's behavior.

Preserve special comments, analyzer instructions, and annotations associated with imports.

If an import cannot be moved safely, preserve it and report the conflict.

## 9. Validation

After organizing imports:

1. Verify that every original import is still present.
2. Verify that no import paths have changed.
3. Verify that aliases and modifiers have been preserved.
4. Confirm that external imports appear first.
5. Confirm that imports are sorted by ascending path length.
6. Confirm that alphabetical tiebreakers are applied correctly.
7. Confirm that responsibility comments correctly describe their imports.
8. Verify that no code outside the import section has changed.
9. Confirm that running the skill again produces no additional changes.

## 10. Final Rule

**EXTERNAL IMPORTS FIRST → PROJECT-OWNED IMPORTS BY PATH LENGTH → ALPHABETICAL TIEBREAKER → RESPONSIBILITY COMMENTS.**

Do not refactor, optimize, or modify any other part of the code.
