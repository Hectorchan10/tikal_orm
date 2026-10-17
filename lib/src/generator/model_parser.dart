part of 'model_analyzer.dart';

Future<AnalyzedProject> _parseProject(
  Iterable<String> modelPaths,
  Iterable<String> seederPaths,
) async {
  Set<String> normalize(Iterable<String> paths) => paths
      .map((path) => File(path).absolute.uri.normalizePath().toFilePath())
      .toSet();
  final models = normalize(modelPaths);
  final seeds = normalize(seederPaths);
  final ordered = {...models, ...seeds}.toList()..sort();
  if (ordered.isEmpty) {
    return (
      models: <String, List<AnalyzedModel>>{},
      seeders: <AnalyzedSeeder>[],
    );
  }
  final contexts = AnalysisContextCollection(includedPaths: ordered);
  final output = <String, List<AnalyzedModel>>{};
  final seedUnits = <ResolvedUnitResult>[];
  try {
    for (final path in ordered) {
      final result = await contexts
          .contextFor(path)
          .currentSession
          .getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        throw FormatException('Cannot resolve $path; run dart pub get first.');
      }
      if (models.contains(path)) output[path] = _modelsFromUnit(result, path);
      if (seeds.contains(path)) seedUnits.add(result);
    }
    return (
      models: output,
      seeders: const SeederAnalyzer().analyzeUnits(seedUnits),
    );
  } finally {
    await contexts.dispose();
  }
}

List<AnalyzedModel> _modelsFromUnit(ResolvedUnitResult result, String path) {
  final edits = <(int, int, String)>[];
  final unit = result.unit;
  final imports = unit.directives.whereType<ImportDirective>().toList();
  for (final node in unit.declarations.whereType<ClassDeclaration>()) {
    final isModel = node.metadata.any(
      (a) =>
          _annotationClass(a.elementAnnotation?.computeConstantValue()) ==
          'TikalTable',
    );
    if (!isModel) continue;
    final name = node.namePart.typeName.lexeme;
    final superclass = node.extendsClause?.superclass;
    if (superclass?.type case InterfaceType type
        when type.element.name == 'TikalModel') {
      edits.add((superclass!.offset, superclass.length, 'TikalModel<$name>'));
    }
    final annotations = [
      ...node.metadata,
      ...node.body.members.whereType<FieldDeclaration>().expand(
        (f) => f.metadata,
      ),
    ];
    for (final annotation in annotations) {
      final value = annotation.elementAnnotation?.computeConstantValue();
      if (_annotationClass(value) == null) {
        if (_annotationNames.contains(
          annotation.name.toSource().split('.').last,
        )) {
          throw FormatException(
            '$path: cannot resolve ${annotation.toSource()}. Check its arguments and imports.',
          );
        }
        continue;
      }
      edits.add((
        annotation.offset,
        annotation.length,
        _annotationSource(value!, imports),
      ));
    }
    for (final field in node.body.members.whereType<FieldDeclaration>().where(
      (f) => !f.isStatic,
    )) {
      if (field.fields.type == null) continue;
      final variable = field.fields.variables.first;
      final type = variable.declaredFragment?.element.type;
      if (type != null) {
        if (!_isCoreType(type)) {
          throw FormatException(
            '$path: unsupported persistent type ${type.getDisplayString()}.',
          );
        }
        edits.add((
          field.fields.type!.offset,
          field.fields.type!.length,
          _typeSource(type),
        ));
      }
    }
    for (final constructor
        in node.body.members.whereType<ConstructorDeclaration>()) {
      for (final parameter in constructor.parameters.parameters) {
        final expression = parameter.defaultClause?.value;
        if (expression == null) continue;
        final value = parameter.declaredFragment?.element
            .computeConstantValue();
        if (value != null) {
          edits.add((
            expression.offset,
            expression.length,
            _constantSource(value),
          ));
        }
      }
    }
  }
  var source = result.content;
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  for (final edit in edits) {
    source = source.replaceRange(edit.$1, edit.$1 + edit.$2, edit.$3);
  }
  final models = _validateModels(source, path: path);
  if (models.isNotEmpty &&
      unit.directives.any(
        (d) =>
            d is PartOfDirective ||
            d is PartDirective &&
                (d.uri.stringValue?.endsWith('.tikal.dart') ?? false),
      )) {
    throw FormatException(
      '$path: remove the generated part directive manually. Models must be standalone libraries; legacy metadata references need an import of generated/tikal.dart.',
    );
  }
  return models;
}

String? _annotationClass(DartObject? value) {
  final type = value?.type;
  if (type is! InterfaceType ||
      !type.element.library.uri.path.endsWith('model/annotations.dart')) {
    return null;
  }
  return type.element.name;
}

bool _isCoreType(DartType type) =>
    type is InterfaceType &&
    type.element.library.uri.toString() == 'dart:core' &&
    type.typeArguments.every(_isCoreType);

String _typeSource(DartType type) {
  if (type is! InterfaceType) return type.getDisplayString();
  final args = type.typeArguments.isEmpty
      ? ''
      : '<${type.typeArguments.map(_typeSource).join(', ')}>';
  return '${type.element.name}$args${type.nullabilitySuffix == NullabilitySuffix.question ? '?' : ''}';
}

String _constantSource(DartObject value) {
  if (value.isNull) return 'null';
  final string = value.toStringValue();
  if (string != null) return _dartLiteral(string);
  final primitive =
      value.toBoolValue() ?? value.toIntValue() ?? value.toDoubleValue();
  if (primitive != null) return primitive.toString();
  throw FormatException('Schema defaults must resolve to scalar constants.');
}

String _annotationSource(DartObject value, List<ImportDirective> imports) {
  final name = _annotationClass(value)!;
  DartObject field(String field) =>
      value.getField(field) ??
      (throw FormatException('Cannot resolve @$name.$field.'));
  String literal(String key) => _constantSource(field(key));
  switch (name) {
    case 'TikalTable':
      return '@TikalTable(${literal('name')}, schema: ${literal('schema')})';
    case 'Column':
      final type = field('type');
      final enumName = type.isNull
          ? null
          : type.getField('_name')?.toStringValue() ?? type.variable?.name;
      if (!type.isNull && enumName == null) {
        throw FormatException('Cannot resolve Column.type.');
      }
      return '@Column(name: ${literal('name')}${enumName == null ? '' : ', type: SqlType.$enumName'})';
    case 'PrimaryKey':
      return '@PrimaryKey(autoIncrement: ${literal('autoIncrement')})';
    case 'Default':
      return '@Default(${literal('value')})';
    case 'VarChar':
      return '@VarChar(${literal('length')})';
    case 'ForeignKey':
      final type = field('references').toTypeValue();
      if (type is! InterfaceType) {
        throw FormatException('ForeignKey requires a concrete entity type.');
      }
      final className = type.element.name!;
      final imported = imports
          .where(
            (i) =>
                i.libraryImport?.namespace.definedNames2[className] ==
                type.element,
          )
          .firstOrNull;
      final prefix = imported?.prefix == null
          ? ''
          : '${imported!.prefix!.name}.';
      return '@ForeignKey(references: $prefix$className)';
    default:
      return '@$name()';
  }
}
