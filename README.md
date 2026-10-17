# TikalORM

> A lightweight, strongly-typed Object-Relational Mapper (ORM) for Dart supporting PostgreSQL, SQLite, and MySQL/MariaDB.

```text
████████╗██╗██╗  ██╗ █████╗ ██╗      ██████╗ ██████╗ ███╗   ███╗
╚══██╔══╝██║██║ ██╔╝██╔══██╗██║     ██╔═══██╗██╔══██╗████╗ ████║
   ██║   ██║█████╔╝ ███████║██║     ██║   ██║██████╔╝██╔████╔██║
   ██║   ██║██╔═██╗ ██╔══██║██║     ██║   ██║██╔══██╗██║╚██╔╝██║
   ██║   ██║██║  ██╗██║  ██║███████╗╚██████╔╝██║  ██║██║ ╚═╝ ██║
   ╚═╝   ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝
```

[![Dart Version](https://img.shields.io/badge/Dart-3.13.5%2B-blue.svg)](https://dart.dev)

---

## 📌 Requirements

* **Dart SDK:** `3.13.5` or higher.

---

## 🚀 Installation

Add `tikal_orm` to your project dependencies:

```bash
dart pub add tikal_orm
```

---

## 🛠️ Getting Started

### 1. Define a Model

Create your model file in `lib/models/user.dart`:

```dart
import 'package:tikal_orm/tikal_orm.dart';

@TikalTable('users')
class User {
  User({this.id, required this.name, required this.email});

  @PrimaryKey(autoIncrement: true)
  int? id;

  String name;

  @Unique()
  String email;
}
```

---

### 2. Code Generation

Run the code generator to generate the static registry and query helpers:

```bash
dart run tikal_orm:tikal generate
```

> **Tip:** Use the watch flag to automatically regenerate files when saving changes:
> ```bash
> dart run tikal_orm:tikal generate --watch
> ```
> *Models are registered automatically—no need to manually pass `models:`.*

---

### 3. Configure and Connect

```dart
import 'models/user.dart';
import 'generated/tikal.dart';

Future<void> main() async {
  // Configure database connection
  await Tikal.configure(
    database: PostgresConfig(
      host: 'localhost',
      port: 5432,
      database: 'my_database',
      username: 'my_username',
      password: 'my_password',
    ),
  );

  try {
    // Insert a record
    final user = await Tikal.save(
      User(name: 'Ana', email: 'ana@example.com'),
    );

    // Fetch records
    final found = await Tikal.find<User>(user.id!);
    final users = await Tikal.all<User>();

    // Update record
    user.name = 'Ana María';
    await Tikal.save(user);

    // Delete record
    await Tikal.delete(user);
  } finally {
    await Tikal.close();
  }
}
```

> ⚠️ **Note:** `configure()` does not automatically create database tables. Tables must exist before performing CRUD operations.

---

## 🗄️ Supported Drivers

<details>
<summary><b>SQLite</b></summary>

```dart
await Tikal.configure(
  database: SqliteConfig(path: 'app.db'),
);
```
</details>

<details>
<summary><b>MySQL / MariaDB</b></summary>

```dart
await Tikal.configure(
  database: MysqlConfig(
    host: 'localhost',
    port: 3306,
    database: 'my_database',
    username: 'my_username',
    password: 'my_password',
  ),
);
```
</details>

<details>
<summary><b>PostgreSQL</b></summary>

```dart
await Tikal.configure(
  database: PostgresConfig(
    host: 'localhost',
    port: 5432,
    database: 'my_database',
    username: 'my_username',
    password: 'my_password',
  ),
);
```
*Note: Schema inspection and migrations are currently available exclusively for PostgreSQL.*
</details>

---

## 🔍 Query Builder

TikalORM provides type-safe query building out of the box:

```dart
final users = await Tikal.query<User>()
    .where(User_.name.equals('Ana'))
    .orderBy(User_.email)
    .get();
```

---

## 🌱 Database Seeders

### Create Seeders

Generate seeder classes using the CLI:

```bash
dart run tikal_orm:tikal make:seeder UserSeeder
dart run tikal_orm:tikal make:seeder DatabaseSeeder
```

### Implement Logic

**1. Individual Seeder** (`lib/seeders/user_seeder.dart`):

```dart
import 'package:tikal_orm/tikal_orm.dart';
import '../models/user.dart';

@Seeder()
class UserSeeder {
  Future<void> run() async {
    await Tikal.save(User(name: 'Admin', email: 'admin@example.com'));
  }
}
```

**2. Main Seeder Runner** (`lib/seeders/database_seeder.dart`):

```dart
import 'package:tikal_orm/tikal_orm.dart';
import 'user_seeder.dart';

@Seeder(calls: [UserSeeder])
class DatabaseSeeder {}
```

> Configure your database connection directly inside `bin/tikal_seed.dart` (or import your existing config). This file is created once and will not be overwritten.

### Run Seeders

```bash
# 1. Regenerate code to register seeders
dart run tikal_orm:tikal generate

# 2. Run all seeders (defaults to DatabaseSeeder)
dart run tikal_orm:tikal db:seed

# Run a specific seeder class
dart run tikal_orm:tikal db:seed --class=UserSeeder
```

### 💡 Seeder Rules & Behavior
* **Reflection-Free / AOT Compatible:** The CLI executes `bin/tikal_seed.dart` using static imports without dynamic reflection.
* **Constructor:** Every seeder class requires an unnamed public constructor with no mandatory parameters.
* **Execution:** `Future<void> run()` is required unless the class delegates entirely via `calls`.
* **Execution Order:** `calls` execute sequentially before the local `run()` method.
* **Error Handling:** Errors stop execution immediately. Ensure your seeders manage duplicate prevention or transactions if needed.