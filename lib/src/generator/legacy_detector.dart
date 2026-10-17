part of 'model_analyzer.dart';

bool _ownsLegacyOutput(
  String content,
  String sourceName,
  List<AnalyzedModel> models,
) {
  final header =
      '// GENERATED CODE - DO NOT MODIFY BY HAND.\n// ignore_for_file: camel_case_types\npart of ${jsonEncode(sourceName)};';
  if (!content.startsWith(header)) return false;
  final parsed = parseString(content: content, throwIfDiagnostics: false);
  if (parsed.errors.isNotEmpty) return false;
  final classes = {
    for (final c in parsed.unit.declarations.whereType<ClassDeclaration>())
      c.namePart.typeName.lexeme: c,
  };
  if (classes.length != models.length ||
      parsed.unit.directives.length != 1 ||
      parsed.unit.directives.single is! PartOfDirective) {
    return false;
  }
  if (parsed.unit.declarations.any(
    (d) => d is! ClassDeclaration && d is! ExtensionDeclaration,
  )) {
    return false;
  }
  for (final model in models) {
    final declaration = classes['${model.name}_'];
    if (declaration == null) return false;
    final fields = {
      for (final field
          in declaration.body.members.whereType<FieldDeclaration>())
        for (final variable in field.fields.variables)
          variable.name.lexeme: variable.initializer?.toSource() ?? '',
    };
    if (!(fields['table']?.contains('TableDefinition<${model.name}>(') ??
        false)) {
      return false;
    }
    if (model.fields.any(
      (f) => !(fields[f.name]?.contains('ModelColumn<${model.name},') ?? false),
    )) {
      return false;
    }
    final repository = declaration.body.members
        .whereType<MethodDeclaration>()
        .where((m) => m.isStatic && m.name.lexeme == 'repository')
        .singleOrNull;
    if (repository == null ||
        !(repository.returnType?.toSource().endsWith(
              'Repository<${model.name}>',
            ) ??
            false) ||
        !repository.body.toSource().contains('definition: table')) {
      return false;
    }
  }
  return true;
}
