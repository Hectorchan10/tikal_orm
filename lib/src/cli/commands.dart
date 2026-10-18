part of 'cli.dart';

const _help = '''TikalORM model-first tooling
  tikal init
  tikal make:seeder UserSeeder
  tikal db:seed [--class=UserSeeder]
  tikal generate [--watch]  (writes mappings and creates lib/tikal.dart once)
  tikal schema diff
  tikal migrate make [name]
  tikal migrate preview
  tikal migrate up [--allow-unsafe]
  tikal migrate down [--allow-destructive]
  tikal migrate status
  tikal migrate check
  tikal db inspect
Configuration: tikal.json (models: list of directories/files, migrations: directory).
Connection: DATABASE_URL / POSTGRES_* / PG* via PostgresConfig.
Generation and preview never connect to PostgreSQL.''';

/// Runs the validated CLI command from the consuming application directory.
Future<void> run(List<String> args, {Directory? directory}) async {
  final root = (directory ?? Directory.current).absolute;
  if (args.isEmpty || args.contains('--help') || args.singleOrNull == '-h') {
    stdout.writeln(_help);
    return;
  }
  final command = _validateArguments(args);
  if (args.first == 'make:seeder') {
    await _makeSeeder(root, args[1]);
    return;
  }
  if (args.first == 'db:seed') {
    await _seedDatabase(root, args);
    return;
  }
  if (!{'init', 'generate'}.contains(args.first)) _guardSchemaEngine();
  if (args.first == 'generate' && args.contains('--watch')) {
    await watchGeneration(root);
    return;
  }
  if (args.first == 'init') {
    _initializeProject(root);
    return;
  }
  final file = _projectFile(root, 'tikal.json');
  final config = file.existsSync()
      ? _configuration(file)
      : _defaultConfiguration;
  final migrationDirectory = _projectDirectory(
    root,
    config['migrations'] as String,
  );
  final migrations = args.first == 'generate'
      ? <Migration>[]
      : _loadMigrations(migrationDirectory);
  if ({'generate', 'schema diff', 'migrate make'}.contains(command)) {
    await _generateOrDiff(root, config, migrationDirectory, migrations, args);
    return;
  }
  if (command == 'migrate preview') {
    for (final m in migrations) {
      stdout.writeln('-- ${m.id}\n${m.up.join(';\n')};');
    }
    return;
  }
  await _runMigrations(command, args, migrations);
}

File _projectFile(Directory root, String path) =>
    File.fromUri(root.uri.resolveUri(Uri.file(path)));
Directory _projectDirectory(Directory root, String path) =>
    Directory.fromUri(root.uri.resolveUri(Uri.file(path)));

void _guardSchemaEngine() {
  final url =
      Platform.environment['DATABASE_URL'] ?? Platform.environment['MYSQL_URL'];
  if (url != null &&
          {'mysql', 'mariadb', 'sqlite'}.contains(Uri.tryParse(url)?.scheme) ||
      (url == null && Platform.environment.containsKey('MYSQL_DATABASE'))) {
    throw const TikalUnsupportedException(
      'Migration and schema CLI commands only support PostgreSQL.',
    );
  }
}

void _initializeProject(Directory root) {
  final config = _projectFile(root, 'tikal.json');
  if (config.existsSync()) {
    _configuration(config);
    _configureEditor(root);
    stdout.writeln('tikal.json already exists; configuration preserved.');
    return;
  }
  config.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(_defaultConfiguration)}\n',
  );
  _projectDirectory(root, 'lib/models').createSync(recursive: true);
  _configureEditor(root);
  stdout.writeln('Created tikal.json and lib/models/.');
  return;
}

Future<void> _generateOrDiff(
  Directory root,
  Map<String, Object?> config,
  Directory migrationDirectory,
  List<Migration> migrations,
  List<String> args,
) async {
  final files = <String>{};
  for (final path in (config['models'] as List).cast<String>()) {
    final source = _projectFile(root, path);
    if (source.existsSync() || _projectDirectory(root, path).existsSync()) {
      files.addAll(
        _modelSources(source, root).map((file) => file.absolute.path),
      );
    } else if (args.first == 'generate') {
      stdout.writeln('Model path absent, treating as empty: $path');
    } else {
      throw StateError('Configured model path does not exist: $path');
    }
  }
  final analyzer = ModelAnalyzer();
  final byFile = <File, List<AnalyzedModel>>{};
  final project = await analyzer.analyzeProject(
    files,
    args.first == 'generate'
        ? {
            ...files,
            ...analyzer.seederCandidates(
              _modelSources(_projectFile(root, 'lib'), root)
                  .map((file) => file.absolute.path)
                  .where((path) => !files.contains(path)),
            ),
          }
        : const [],
  );
  for (final entry in project.models.entries) {
    if (entry.value.isNotEmpty) byFile[File(entry.key)] = entry.value;
  }
  if (byFile.isEmpty && args.first != 'generate') {
    throw StateError('No @TikalTable models found in configured paths.');
  }
  final all = byFile.values.expand((m) => m).toList();
  if (args.first == 'generate') {
    await _generateMappings(
      root,
      byFile,
      analyzer,
      project.seeders,
      project.constructors,
    );
    return;
  }
  analyzer.resolveForeignKeys(all);
  final snapshot = analyzer.schemaSnapshot(all);
  final before = migrations.isEmpty
      ? SchemaSnapshot([])
      : migrations.last.snapshot;
  final diff = SchemaDiffer().compare(before, snapshot);
  if (diff.up.isEmpty) {
    stdout.writeln('No schema changes.');
    return;
  }
  stdout.writeln('${diff.up.join(';\n')};');
  if (diff.requiresReview) {
    stdout.writeln(
      'Review required: type conversion or NOT NULL can fail or lose data.',
    );
  }
  if (args.first == 'schema') return;
  final name = args.length == 3 ? args[2] : 'schema';
  final now = DateTime.now().toUtc();
  final id =
      '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}${(now.millisecond * 1000 + now.microsecond).toString().padLeft(6, '0')}_$name';
  final migration = Migration(
    id: id,
    up: diff.up,
    down: diff.down,
    snapshot: snapshot,
    requiresReview: diff.requiresReview,
    destructiveDown: diff.destructiveDown,
  );
  migrationDirectory.createSync(recursive: true);
  final output = File('${migrationDirectory.path}/$id.json');
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(migration.toJson())}\n',
  );
  stdout.writeln('Created ${output.path}. Review before applying.');
  return;
}
