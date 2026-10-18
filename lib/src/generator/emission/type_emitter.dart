part of '../model_analyzer.dart';

final class _EmissionTypes {
  _EmissionTypes(Iterable<AnalyzedModel> models) {
    final uris = <String>{};
    for (final field in models.expand((m) => m.fields)) {
      final conversion = field.conversion;
      if (conversion == null) continue;
      for (final source in [conversion.dartType, conversion.expression]) {
        uris.addAll(_marker.allMatches(source).map((m) => m[1]!));
      }
    }
    final sorted = uris.toList()..sort();
    for (final (index, uri) in sorted.indexed) {
      prefixes[uri] = uri == 'package:tikal_orm/tikal_orm.dart'
          ? 'orm'
          : 't$index';
    }
  }
  static final _marker = RegExp('§([^§]+)§');
  final prefixes = <String, String>{};
  String resolve(String source) =>
      source.replaceAllMapped(_marker, (m) => '${prefixes[m[1]]}.');
  String valueType(AnalyzedField field) =>
      resolve(field.conversion?.dartType ?? field.valueType);
}
