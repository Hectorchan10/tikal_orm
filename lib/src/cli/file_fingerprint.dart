import 'dart:io';

import 'package:meta/meta.dart';
import 'package:crypto/crypto.dart';

/// Per-watcher content cache; metadata is a hint, never the only change signal.
@internal
final class FileFingerprintCache {
  /// Creates an empty watcher-local cache.
  FileFingerprintCache();

  final _entries = <String, ((int, DateTime, DateTime), String)>{};
  final _dirty = <String>{};

  /// Number of physical content reads, for tooling measurements.
  int reads = 0;

  /// Total bytes physically read, excluding cached lookups.
  int bytesRead = 0;

  /// Marks an event path for content reconciliation on its next scan.
  void invalidate(String path) => _dirty.add(File(path).absolute.path);

  /// Returns a content hash, rereading dirty/changed files or forced reconciliations.
  String read(File file, {bool force = false}) {
    final path = file.absolute.path;
    final stat = file.statSync();
    final signature = (stat.size, stat.modified, stat.changed);
    final old = _entries[path];
    if (!force && !_dirty.contains(path) && old?.$1 == signature) {
      return old!.$2;
    }
    final bytes = file.readAsBytesSync();
    reads++;
    bytesRead += bytes.length;
    final hash = sha256.convert(bytes).toString();
    // A subsequent scan must retry files modified during the read.
    if (file.statSync().modified == stat.modified &&
        file.statSync().size == stat.size) {
      _entries[path] = (signature, hash);
      _dirty.remove(path);
    }
    return hash;
  }

  /// Drops removed paths so recreations cannot inherit stale content hashes.
  void retain(Set<String> paths) {
    _entries.removeWhere((key, _) => !paths.contains(key));
    _dirty.removeWhere((key) => !paths.contains(key));
  }
}
