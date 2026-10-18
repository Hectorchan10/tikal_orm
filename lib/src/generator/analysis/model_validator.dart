part of '../model_analyzer.dart';

List<AnalyzedModel> _validateModels(
  String source, {
  String? path,
  Map<String, AnalyzedConversion> conversions = const {},
}) {
  final unit = parseString(content: source, path: path).unit;
  final models = <AnalyzedModel>[];
  for (final node in unit.declarations.whereType<ClassDeclaration>()) {
    final annotation = _annotations(node.metadata, table: true)['TikalTable'];
    if (annotation == null) continue;
    final name = node.namePart.typeName.lexeme;
    if (name.startsWith('_')) {
      throw FormatException('$name must be public for centralized generation.');
    }
    if (node.extendsClause != null) {
      throw FormatException(
        '$name must declare its persistent fields directly; inheritance is unsupported.',
      );
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
    validateSchemaIdentifier('${tableName}_pkey');
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
        if (!field.isStatic && !_isRelationField(field))
          _analyzeField(
            field,
            name,
            parameters,
            conversions['$name.${field.fields.variables.first.name.lexeme}'],
          ),
    ];
    final relations = [
      for (final field in members.whereType<FieldDeclaration>())
        if (!field.isStatic && _isRelationField(field))
          _analyzeRelation(field, parameters),
    ];
    if ({
          ...fields.map((f) => f.name),
          ...relations.map((r) => r.name),
        }.length !=
        fields.length + relations.length) {
      throw FormatException(
        '$name has duplicate persistent/relation field names.',
      );
    }
    if (fields.where((f) => f.column.primaryKey).length > 1) {
      throw FormatException(
        '$name: composite primary keys are unsupported for model persistence. Use a surrogate primary key and a UniqueConstraint; internal ManyToMany bridges are unaffected.',
      );
    }
    if (!fields.any((f) => f.column.primaryKey)) {
      throw FormatException('$name requires at least one PrimaryKey.');
    }
    if (fields.map((f) => f.column.name).toSet().length != fields.length) {
      throw FormatException('$name has duplicate column names.');
    }
    if (fields.where((f) => f.version).length > 1 ||
        fields.where((f) => f.createdAt).length > 1 ||
        fields.where((f) => f.updatedAt).length > 1 ||
        fields.where((f) => f.deletedAt).length > 1) {
      throw FormatException(
        '$name may have only one Version, CreatedAt, UpdatedAt and DeletedAt field.',
      );
    }
    for (final f in fields.where((f) => f.target != null)) {
      validateSchemaIdentifier('${tableName}_${f.column.name}_fkey');
    }
    for (final f in fields.where((f) => f.column.unique)) {
      validateSchemaIdentifier('${tableName}_${f.column.name}_key');
    }
    for (final p in constructor.parameters.parameters) {
      if (!fields.any((f) => f.name == p.name?.lexeme) &&
          !relations.any((r) => r.name == p.name?.lexeme)) {
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
          indexes: _modelIndexes(node.metadata, fields, name),
          uniqueConstraints: _modelUniqueConstraints(
            node.metadata,
            fields,
            name,
          ),
        ),
        fields,
        constructor,
      )..relations.addAll(relations),
    );
  }
  return models;
}

String _snake(String s) => s
    .replaceAllMapped(RegExp(r'([A-Z]+)([A-Z][a-z])'), (m) => '${m[1]}_${m[2]}')
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase();
const _annotationNames = {
  'TikalTable',
  'Version',
  'Column',
  'PrimaryKey',
  'Uuid',
  'UuidGenerated',
  'Unique',
  'Index',
  'UniqueConstraint',
  'VarChar',
  'Default',
  'CreatedAt',
  'UpdatedAt',
  'DeletedAt',
  'ForeignKey',
  'Decimal',
  'Convert',
  'Enumerated',
  'DbType',
  'ManyToMany',
  'HasMany',
  'BelongsTo',
  'OneToOne',
};
