part of 'cli.dart';

/// Development loop with metadata caching, filesystem invalidation and periodic
/// content reconciliation. Same-timestamp edits and atomic replacements are detected.
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
  final cache = FileFingerprintCache();
  StreamSubscription<FileSystemEvent>? changes;
  try {
    changes = root
        .watch(recursive: true)
        .listen(
          (event) => cache.invalidate(event.path),
          onError: (Object _) {
            /* Periodic reconciliation preserves detection on watch failure. */
          },
        );
  } on FileSystemException {
    // Unsupported filesystem watches fall back to polling and full reconciliation.
  } on UnsupportedError {
    // Some platforms do not implement recursive filesystem watches.
  }
  var nextReconciliation = DateTime.now();
  String fingerprint() {
    final now = DateTime.now();
    final force = !now.isBefore(nextReconciliation);
    if (force) nextReconciliation = now.add(const Duration(seconds: 2));
    return _generationFingerprint(root, cache, force: force);
  }

  String? attempted;
  stdout.writeln(
    'Watching Dart models and configuration. Press Ctrl+C to stop.',
  );
  try {
    while (!stopped.isCompleted) {
      try {
        final input = fingerprint();
        if (input != attempted) {
          // Require one quiet interval to coalesce rapid editor saves.
          await pause();
          if (stopped.isCompleted) break;
          if (fingerprint() != input) continue;
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
            attempted = null; // Retry transient read/write failures after a quiet interval.
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
    await changes?.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}

String _generationFingerprint(
  Directory root,
  FileFingerprintCache cache, {
  bool force = false,
}) {
  File file(String path) => File.fromUri(root.uri.resolveUri(Uri.file(path)));
  final output = file('lib/generated/tikal.dart').absolute.path;
  final inputs = <String, String>{};
  void read(File source) {
    if (!source.existsSync() || inputs.containsKey(source.absolute.path)) {
      return;
    }
    inputs[source.absolute.path] = cache.read(source, force: force);
  }

  void scan(String path) {
    final source = file(path);
    if (source.existsSync()) {
      if (source.path != output) {
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
  cache.retain(inputs.keys.toSet());
  final ordered = inputs.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({for (final path in ordered) path: inputs[path]}),
        ),
      )
      .toString();
}
