part of 'cli.dart';

/// Development-only generation loop. Polls content, not timestamps, so editor
/// replacements and directory creation/removal work across Dart/Flutter hosts.
/// [stop] permits embedding/tests; the CLI otherwise stops on Ctrl+C or SIGTERM.
Future<void> watchGeneration(
  Directory root, {
  Stream<void>? stop,
  Duration interval = const Duration(milliseconds: 500),
}) async {
  if (interval <= Duration.zero) {
    throw ArgumentError.value(interval, 'interval');
  }
  final stopped = Completer<void>();
  final subscriptions = <StreamSubscription<void>>[];
  void finish() {
    if (!stopped.isCompleted) stopped.complete();
  }

  if (stop != null) {
    subscriptions.add(stop.listen((_) => finish(), onDone: finish));
  } else {
    subscriptions.add(ProcessSignal.sigint.watch().listen((_) => finish()));
    if (!Platform.isWindows) {
      subscriptions.add(ProcessSignal.sigterm.watch().listen((_) => finish()));
    }
  }
  Future<void> pause() =>
      Future.any([Future<void>.delayed(interval), stopped.future]);
  String? attempted;
  stdout.writeln(
    'Watching Dart models and configuration. Press Ctrl+C to stop.',
  );
  try {
    while (!stopped.isCompleted) {
      try {
        final input = _generationFingerprint(root);
        if (input != attempted) {
          // Require one quiet interval to coalesce rapid editor saves.
          await pause();
          if (stopped.isCompleted) break;
          if (_generationFingerprint(root) != input) continue;
          attempted = input;
          try {
            await run(['generate'], directory: root);
          } on TikalException catch (error) {
            stderr.writeln('Generation failed: $error');
          } on FormatException catch (error) {
            stderr.writeln('Generation failed: ${error.message}');
          } on StateError catch (error) {
            stderr.writeln('Generation failed: ${error.message}');
          } on ArgumentError catch (error) {
            stderr.writeln('Generation failed: ${error.message}');
          } on FileSystemException catch (error) {
            stderr.writeln('Generation failed: $error');
          }
        }
      } on FileSystemException catch (error) {
        // A file can disappear between directory enumeration and reading it.
        stderr.writeln('Cannot read generation inputs: $error');
      }
      await pause();
    }
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

String _generationFingerprint(Directory root) {
  File file(String path) => File.fromUri(root.uri.resolveUri(Uri.file(path)));
  final output = file('lib/generated/tikal.dart').absolute.path;
  final inputs = <String, String>{};
  void read(File source) {
    if (!source.existsSync() || inputs.containsKey(source.absolute.path)) {
      return;
    }
    inputs[source.absolute.path] = sha256
        .convert(source.readAsBytesSync())
        .toString();
  }

  void scan(String path) {
    final source = file(path);
    if (source.existsSync()) {
      if (source.path != output && !source.path.endsWith('.tikal.dart')) {
        read(source);
      }
      return;
    }
    final directory = Directory(source.path);
    if (!directory.existsSync()) return;
    for (final child in _modelSources(source, root)) {
      read(child);
    }
  }

  // Local imports may provide annotation constants, aliases or defaults outside
  // model directories. Package configuration changes also invalidate analysis.
  for (final path in [
    'tikal.json',
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
  ]) {
    read(file(path));
  }
  scan('lib');
  final configFile = file('tikal.json');
  var paths = <String>['lib/models'];
  if (configFile.existsSync()) {
    try {
      paths = (_configuration(configFile)['models'] as List).cast<String>();
    } on FormatException {
      /* Generation reports the configuration error once. */
    }
  }
  for (final path in paths) {
    scan(path);
  }
  final ordered = inputs.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({for (final path in ordered) path: inputs[path]}),
        ),
      )
      .toString();
}
