part of 'cli.dart';

List<Migration> _loadMigrations(Directory migrationDirectory) {
  final migrations = <Migration>[];
  if (migrationDirectory.existsSync()) {
    final files =
        migrationDirectory
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final migration = _readMigration(f);
      if (f.uri.pathSegments.last != '${migration.id}.json') {
        throw StateError('Migration filename must match its id: ${f.path}');
      }
      migrations.add(migration);
    }
  }
  return migrations;
}

Future<void> _runMigrations(
  String command,
  List<String> args,
  List<Migration> migrations,
) async {
  final db = TikalDatabase(PostgresConfig.fromEnvironment());
  try {
    final runner = MigrationRunner(db);
    switch (command) {
      case 'migrate up':
        await runner.up(
          migrations,
          allowUnsafe: args.contains('--allow-unsafe'),
        );
        stdout.writeln('Migrations applied.');
      case 'migrate down':
        await runner.down(
          migrations,
          allowDestructive: args.contains('--allow-destructive'),
        );
        stdout.writeln('Rollback complete.');
      case 'migrate status':
        final status = await runner.status(migrations);
        for (final entry in status.entries) {
          stdout.writeln('${entry.value ? 'applied' : 'pending'} ${entry.key}');
        }
      case 'migrate check':
        final differences = await runner.check(migrations);
        if (differences.isEmpty) {
          stdout.writeln('Applied schema matches PostgreSQL.');
        } else {
          differences.forEach(stdout.writeln);
          exitCode = 2;
        }
      case 'db inspect':
        final snapshot = await SchemaInspector(db).inspect();
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(snapshot.toJson()),
        );
    }
  } finally {
    await db.close();
  }
}
