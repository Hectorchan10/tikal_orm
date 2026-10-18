part of 'cli.dart';

const _defaultConfiguration = <String, Object?>{
  'models': ['lib/models'],
  'migrations': 'migrations',
};

/// Explicit files preserve the configured input; directory discovery excludes
/// generated libraries so output never becomes a model input.
Iterable<File> _modelSources(File source, Directory root) sync* {
  if (source.existsSync()) {
    yield source;
    return;
  }
  final directory = Directory(source.path);
  if (!directory.existsSync()) return;
  final output = File.fromUri(root.uri.resolve('lib/generated/tikal.dart'));
  yield* directory
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where(
        (file) =>
            file.path.endsWith('.dart') &&
            file.absolute.path != output.absolute.path,
      );
}

String _validateArguments(List<String> args) {
  final command = args.take(2).join(' ');
  final valid = switch (args) {
    ['init'] ||
    ['generate'] ||
    ['generate', '--watch'] ||
    ['schema', 'diff'] ||
    ['db', 'inspect'] ||
    ['migrate', 'make'] ||
    ['migrate', 'up'] ||
    ['migrate', 'up', '--allow-unsafe'] ||
    ['migrate', 'down'] ||
    ['migrate', 'down', '--allow-destructive'] ||
    ['migrate', 'preview'] ||
    ['migrate', 'status'] ||
    ['migrate', 'check'] => true,
    ['make:seeder', final name] => RegExp(
      r'^[A-Z][a-zA-Z0-9_]*$',
    ).hasMatch(name),
    ['db:seed'] => true,
    ['db:seed', final option] => RegExp(
      r'^--class=[A-Z][a-zA-Z0-9_]*$',
    ).hasMatch(option),
    ['migrate', 'make', final name] => RegExp(
      r'^[a-zA-Z0-9_]+$',
    ).hasMatch(name),
    _ => false,
  };
  if (!valid) {
    throw ArgumentError(
      'Invalid command or arguments: ${args.join(' ')}\n$_help',
    );
  }
  return command;
}

Map<String, Object?> _jsonObject(File file) {
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, Object?>) {
    throw FormatException('${file.path} must contain a JSON object.');
  }
  return value;
}

Map<String, Object?> _configuration(File file) {
  final config = _jsonObject(file);
  final models = config['models'];
  final migrations = config['migrations'];
  if (models is! List ||
      models.isEmpty ||
      models.any((p) => p is! String || p.isEmpty) ||
      migrations is! String ||
      migrations.isEmpty) {
    throw FormatException(
      '${file.path}: models must be a nonempty list of paths and migrations a directory path.',
    );
  }
  return config;
}

Migration _readMigration(File file) {
  try {
    return Migration.fromJson(_jsonObject(file));
  } on TypeError {
    throw FormatException(
      '${file.path}: invalid migration or snapshot field types.',
    );
  }
}
