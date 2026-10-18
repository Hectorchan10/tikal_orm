# TikalORM

A framework-neutral Dart ORM for PostgreSQL, SQLite and MySQL/MariaDB.
Version **0.2.0** requires Dart **3.13.5+**. One package, static generation, no reflection.

## Install

```sh
dart pub add tikal_orm
```

## Define a model

Create `lib/models/user.dart`:

```dart
import 'package:tikal_orm/tikal_orm.dart';

@TikalTable('users')
class User {
  @PrimaryKey(autoIncrement: true)
  int? id;
  String name;
  @Unique()
  String email;
  @Version()
  int version = 1;
}
```

No constructor is required in the model source before generation. `generate`
adds named parameters automatically: nullable fields are optional, and non-null
fields without defaults are required. Literal field defaults, `@Default` and
`@Version` are respected. Relation lists keep their field initializers.

The generated constructor carries a comment marker and updates when fields change.
Remove that marker before customizing the constructor yourself; manual constructors
are preserved. Run generation before analyzing or building the consuming app.

## Generate

```sh
dart run tikal_orm:tikal generate
```

Generation creates `lib/generated/tikal.dart` and the application entry `lib/tikal.dart`.
Generate before analyzing/building the app. See [generation and editor setup](docs/typed-queries.md#generate).

## Connect and query

```dart
import 'models/user.dart';
import 'tikal.dart';

Future<void> main() async {
  await Tikal.configure(database: SqliteConfig(path: 'app.db'));
  final remove = Tikal.onQuery((event) => print(event.sql));
  try {
    final user = await Tikal.model<User>().save(User(name: 'Ana', email: 'ana@example.com'));
    user.name = 'Ana María';
    await Tikal.model<User>().save(user);
    final users = await Tikal.model<User>().query()
        .where(User_.name.startsWith('Ana'))
        .orderBy(User_.id)
        .get();
    print(users.length);
  } finally {
    remove();
    await Tikal.close();
  }
}
```

Tables must already exist. Configuration and queries never create or reconcile schema.
`@Version` guards individual updates and `delete(model)`, including physical deletion.
Resolve `TikalConcurrencyException` explicitly. `forceDelete(model)` deliberately
bypasses both soft deletion and version checks. Key-only hard deletes are unchanged.

## Documentation

- [Engines and supported field types](docs/engines.md)
- [Typed queries, generation and conventions](docs/typed-queries.md)
- [Transactions](docs/transactions.md)
- [Schema, explicit DDL, bulk writes and indexes](docs/schema-and-ddl.md)
- [Relations and seeders](docs/relations-and-seeders.md)
- [Constraint errors and safe logging](docs/errors.md)
- [Internal layout and invariants](docs/internal-layout.md)
- [Public API](lib/tikal_orm.dart)
- [Migration notes](CHANGELOG.md)
- [Dependencies and performance decisions](docs/dependencies-and-performance.md)
