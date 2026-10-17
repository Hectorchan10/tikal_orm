part of 'model_analyzer.dart';

List<AnalyzedModel> _validateModels(String source, {String? path}) {
  final unit = parseString(content: source, path: path).unit;
  final models = <AnalyzedModel>[];
  for (final node in unit.declarations.whereType<ClassDeclaration>()) {
    final annotation = _annotations(node.metadata)['TikalTable'];
    if (annotation == null) continue;
    final name = node.namePart.typeName.lexeme;
    if (name.startsWith('_')) {
      throw FormatException('$name must be public for centralized generation.');
    }
    if (node.extendsClause != null &&
        node.extendsClause?.superclass.toSource() != 'TikalModel<$name>') {
      throw FormatException('$name must extend TikalModel<$name>.');
    }
    if (node.abstractKeyword != null || node.namePart.typeParameters != null) {
      throw FormatException('$name must be a concrete non-generic model.');
    }
    final tableName = _string(_positional(annotation).single);
    final schemaArg = _named(annotation, 'schema');
    final schema = schemaArg == null || schemaArg is NullLiteral
        ? null
        : _string(schemaArg);
    validateSchemaIdentifier(tableName);
    if (schema != null) validateSchemaIdentifier(schema);
    final members = node.body.members;
    final generative = members
        .whereType<ConstructorDeclaration>()
        .where((c) => c.factoryKeyword == null)
        .toList();
    final unnamed = generative.where((c) => c.name == null).toList();
    final constructors = unnamed.isEmpty ? generative : unnamed;
    if (constructors.length != 1) {
      throw FormatException(
        '$name needs an unambiguous generative constructor (prefer an unnamed constructor).',
      );
    }
    final constructor = constructors.single;
    if (constructor.name?.lexeme.startsWith('_') ?? false) {
      throw FormatException('$name needs a public constructor.');
    }
    final parameters = {
      for (final p in constructor.parameters.parameters) p.name?.lexeme: p,
    };
    final fields = <AnalyzedField>[
      for (final field in members.whereType<FieldDeclaration>())
        if (!field.isStatic) _analyzeField(field, name, parameters),
    ];
    if (fields.where((f) => f.column.primaryKey).length != 1) {
      throw FormatException('$name requires exactly one PrimaryKey.');
    }
    if (fields.map((f) => f.column.name).toSet().length != fields.length) {
      throw FormatException('$name has duplicate column names.');
    }
    if (fields.where((f) => f.createdAt).length > 1 ||
        fields.where((f) => f.updatedAt).length > 1 ||
        fields.where((f) => f.deletedAt).length > 1) {
      throw FormatException(
        '$name may have only one CreatedAt, UpdatedAt and DeletedAt field.',
      );
    }
    for (final f in fields.where((f) => f.target != null)) {
      if (fields.any((other) => other.name == '${f.name}Relation')) {
        throw FormatException(
          'Generated relationship conflicts with ${f.name}Relation.',
        );
      }
      validateSchemaIdentifier('${tableName}_${f.column.name}_fkey');
    }
    for (final f in fields.where((f) => f.column.unique)) {
      validateSchemaIdentifier('${tableName}_${f.column.name}_key');
    }
    for (final p in constructor.parameters.parameters) {
      if (!fields.any((f) => f.name == p.name?.lexeme)) {
        throw FormatException(
          '$name: constructor must use named persistent field parameters.',
        );
      }
    }
    models.add(
      AnalyzedModel(
        name,
        SchemaTable(
          name: tableName,
          schema: schema,
          columns: fields.map((f) => f.column),
        ),
        fields,
        constructor,
      )..legacy = node.extendsClause != null,
    );
  }
  return models;
}

String _snake(String s) =>
    s.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
const _annotationNames = {
  'TikalTable',
  'Column',
  'PrimaryKey',
  'Uuid',
  'UuidGenerated',
  'Unique',
  'VarChar',
  'Default',
  'CreatedAt',
  'UpdatedAt',
  'DeletedAt',
  'ForeignKey',
};
