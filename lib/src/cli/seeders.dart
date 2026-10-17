part of 'cli.dart';

Future<void> _makeSeeder(Directory root, String name) async {
  final filename = name
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match[1]}_${match[2]}',
      )
      .toLowerCase();
  final output = File.fromUri(root.uri.resolve('lib/seeders/$filename.dart'));
  if (output.existsSync()) {
    throw StateError('Seeder already exists: ${output.path}');
  }
  output.parent.createSync(recursive: true);
  output.writeAsStringSync('''import 'package:tikal_orm/tikal_orm.dart';

@Seeder()
class $name {
  Future<void> run() async {
    // Add your database writes here.
  }
}
''');
  final runner = File.fromUri(root.uri.resolve('bin/tikal_seed.dart'));
  if (!runner.existsSync()) {
    runner.parent.createSync(recursive: true);
    runner.writeAsStringSync(_seedRunner);
    stdout.writeln('Configure your connection in bin/tikal_seed.dart.');
  }
  stdout.writeln('Created ${output.path}. Run tikal generate.');
}

Future<void> _seedDatabase(Directory root, List<String> args) async {
  final runner = File.fromUri(root.uri.resolve('bin/tikal_seed.dart'));
  final generated = File.fromUri(root.uri.resolve('lib/generated/tikal.dart'));
  if (!runner.existsSync()) {
    throw StateError(
      'Create bin/tikal_seed.dart with your connection setup, or scaffold it with tikal make:seeder DatabaseSeeder.',
    );
  }
  if (!generated.existsSync()) {
    throw StateError('Run tikal generate before db:seed.');
  }
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', runner.path, ...args.skip(1)],
    workingDirectory: root.path,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}

// Application-owned bootstrap: generated only by make:seeder, never overwritten.
const _seedRunner = '''import '../lib/generated/tikal.dart';

Future<void> main(List<String> args) async {
  if (args.length > 1 ||
      (args.isNotEmpty && !RegExp(r'^--class=[A-Z][a-zA-Z0-9_]*\$').hasMatch(args.single))) {
    throw ArgumentError('Usage: dart run bin/tikal_seed.dart [--class=UserSeeder]');
  }
  await Tikal.configure(
    database: PostgresConfig(
      host: 'localhost',
      port: 5432,
      database: 'app',
      username: 'app',
      password: 'your_password',
    ),
  );
  try {
    await tikalSeeders.run(
      className: args.isEmpty ? 'DatabaseSeeder' : args.single.substring('--class='.length),
    );
  } finally {
    await Tikal.close();
  }
}
''';
