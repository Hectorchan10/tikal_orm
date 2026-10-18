part of '../model_analyzer.dart';

Iterable<SchemaIndex> _modelIndexes(
  NodeList<Annotation> metadata,
  List<AnalyzedField> fields,
  String model,
) sync* {
  for (final annotation in metadata) {
    if (annotation.name.toSource() != 'Index') continue;
    yield SchemaIndex(
      name: _indexName(annotation),
      columns: _indexColumns(annotation, fields, model),
    );
  }
}

Iterable<SchemaUniqueConstraint> _modelUniqueConstraints(
  NodeList<Annotation> metadata,
  List<AnalyzedField> fields,
  String model,
) sync* {
  for (final annotation in metadata) {
    if (annotation.name.toSource() != 'UniqueConstraint') continue;
    yield SchemaUniqueConstraint(
      name: _indexName(annotation),
      columns: _indexColumns(annotation, fields, model),
    );
  }
}

String _indexName(Annotation annotation) {
  final name = _named(annotation, 'name');
  if (name == null) throw FormatException('Index/UNIQUE requires a name.');
  return _string(name);
}

List<String> _indexColumns(
  Annotation annotation,
  List<AnalyzedField> fields,
  String model,
) {
  final expression = _named(annotation, 'columns');
  if (expression is! ListLiteral ||
      expression.elements.any((e) => e is! StringLiteral)) {
    throw FormatException(
      'Index/UNIQUE columns must be a constant list of Dart field names.',
    );
  }
  return expression.elements.map((e) {
    final name = _string(e as Expression);
    final field = fields.where((f) => f.name == name).firstOrNull;
    if (field == null) {
      throw FormatException(
        '$model: index/UNIQUE references unknown Dart field "$name".',
      );
    }
    return field.column.name;
  }).toList();
}
