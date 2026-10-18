part of '../model_analyzer.dart';

List<String> _seederCandidates(Iterable<String> paths) {
  final candidates = <String>[];
  final ordered = paths.map((p) => File(p).absolute.path).toSet().toList()
    ..sort();
  for (final path in ordered) {
    final source = File(path).readAsStringSync();
    if (!source.contains('@')) continue;
    // Keep all annotated classes: aliases and imported const annotations cannot
    // safely be filtered by spelling. Imports resolve in the shared semantic session.
    final unit = parseString(
      content: source,
      path: path,
      throwIfDiagnostics: false,
    ).unit;
    if (unit.declarations.whereType<ClassDeclaration>().any(
      (node) => node.metadata.isNotEmpty,
    )) {
      candidates.add(path);
    }
  }
  return candidates;
}
