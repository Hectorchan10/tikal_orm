part of '../model_analyzer.dart';

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
      constructors: <String, ConstructorUpdate>{},
    );
  }
  final contexts = AnalysisContextCollection(includedPaths: ordered);
  final output = <String, List<AnalyzedModel>>{};
  final seedUnits = <ResolvedUnitResult>[];
  final constructors = <String, ConstructorUpdate>{};
  try {
    for (final path in ordered) {
      final result = await contexts
          .contextFor(path)
          .currentSession
          .getResolvedUnit(path);
      if (result is! ResolvedUnitResult) {
        throw FormatException('Cannot resolve $path; run dart pub get first.');
      }
      if (models.contains(path)) {
        output[path] = await _modelsFromUnit(result, path, constructors);
      }
      if (seeds.contains(path)) seedUnits.add(result);
    }
    return (
      models: output,
      seeders: const SeederAnalyzer().analyzeUnits(seedUnits),
      constructors: constructors,
    );
  } finally {
    await contexts.dispose();
  }
}

Future<List<AnalyzedModel>> _modelsFromUnit(
  ResolvedUnitResult result,
  String path,
  Map<String, ConstructorUpdate> constructors,
) async {
  final conversions = <String, AnalyzedConversion>{};
  final edits = <(int, int, String)>[];
  final constructorEdits = <(int, int, String)>[];
  final unit = result.unit;
  final imports = unit.directives.whereType<ImportDirective>().toList();
  for (final node in unit.declarations.whereType<ClassDeclaration>()) {
    final isModel = node.metadata.any(
      (a) =>
          _annotationClass(a.elementAnnotation?.computeConstantValue()) ==
          'TikalTable',
    );
    if (!isModel) continue;
    final constructor = _constructorEdit(node);
    if (constructor != null) constructorEdits.add(constructor);
    final name = node.namePart.typeName.lexeme;
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
      if ({'Convert', 'Enumerated'}.contains(_annotationClass(value))) {
        edits.add((annotation.offset, annotation.length, ''));
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
      if (_isRelationField(field)) {
        final type =
            field.fields.variables.first.declaredFragment?.element.type;
        if (type != null) {
          edits.add((
            field.fields.type!.offset,
            field.fields.type!.length,
            _typeSource(type),
          ));
        }
        continue;
      }
      final conversion = await _conversionFor(field, result);
      final variable = field.fields.variables.first;
      if (conversion != null) {
        conversions['$name.${variable.name.lexeme}'] = conversion;
      }
      final type = variable.declaredFragment?.element.type;
      if (type != null) {
        if (conversion == null && !_isCoreType(type)) {
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
      if (_isManagedConstructor(constructor)) continue;
      for (final parameter in constructor.parameters.parameters) {
        final expression = parameter.defaultClause?.value;
        if (expression == null ||
            node.body.members.whereType<FieldDeclaration>().any(
              (f) =>
                  _isRelationField(f) &&
                  f.fields.variables.any(
                    (v) => v.name.lexeme == parameter.name?.lexeme,
                  ),
            )) {
          continue;
        }
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
  if (constructorEdits.isNotEmpty) {
    constructors[path] = (
      original: result.content,
      updated: _applyEdits(result.content, constructorEdits),
    );
  }
  final source = _applyEdits(result.content, [...edits, ...constructorEdits]);
  final models = _validateModels(source, path: path, conversions: conversions);
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
    {
      'dart:core',
      'dart:typed_data',
    }.contains(type.element.library.uri.toString()) &&
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
    case 'Index':
    case 'UniqueConstraint':
      final columns = field('columns').toListValue();
      if (columns == null || columns.any((c) => c.toStringValue() == null)) {
        throw FormatException(
          '$name.columns must be constant Dart field names.',
        );
      }
      return '@$name(name: ${literal('name')}, columns: [${columns.map(_constantSource).join(', ')}])';
    case 'Default':
      return '@Default(${literal('value')})';
    case 'BelongsTo':
    case 'OneToOne':
    case 'ManyToMany':
    case 'HasMany':
      final target = field('target').toTypeValue();
      if (target is! InterfaceType) {
        throw FormatException('Relation target must be a model type.');
      }
      if (name == 'BelongsTo') {
        return '@BelongsTo(${target.element.name}, foreignKey: ${literal('foreignKey')})';
      }
      if (name == 'OneToOne') {
        return '@OneToOne(${target.element.name}, mappedBy: ${literal('mappedBy')})';
      }
      return '@$name(${target.element.name}, mappedBy: ${literal('mappedBy')}${name == 'HasMany' ? '' : ', joinTable: ${literal('joinTable')}, joinColumn: ${literal('joinColumn')}, inverseJoinColumn: ${literal('inverseJoinColumn')}'})';
    case 'DbType':
      return '@DbType(postgres: ${literal('postgres')}, mysql: ${literal('mysql')}, sqlite: ${literal('sqlite')})';
    case 'Decimal':
      return '@Decimal(${literal('precision')}, ${literal('scale')})';
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
      return '@ForeignKey(references: $prefix$className, onDelete: ReferentialAction.${field('onDelete').getField('_name')!.toStringValue()}, onUpdate: ReferentialAction.${field('onUpdate').getField('_name')!.toStringValue()})';
    default:
      return '@$name()';
  }
}
