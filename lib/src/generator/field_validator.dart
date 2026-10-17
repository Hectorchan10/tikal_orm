part of 'model_analyzer.dart';

AnalyzedField _analyzeField(
  FieldDeclaration field,
  String name,
  Map<String?, FormalParameter> parameters,
) {
  if (field.fields.isFinal ||
      field.fields.isConst ||
      field.fields.type == null) {
    throw FormatException(
      '$name: persistent fields must be mutable and explicitly typed.',
    );
  }
  if (field.fields.variables.length != 1) {
    throw FormatException('$name: declare one field per declaration.');
  }
  final variable = field.fields.variables.single;
  final fieldName = variable.name.lexeme;
  if (fieldName.startsWith('_')) {
    throw FormatException(
      '$name.$fieldName must be public for centralized generation.',
    );
  }
  if (fieldName == 'table' || fieldName == 'repository') {
    throw FormatException(
      '$name.$fieldName conflicts with generated metadata.',
    );
  }
  final dartType = field.fields.type!.toSource();
  final baseType = dartType.endsWith('?')
      ? dartType.substring(0, dartType.length - 1)
      : dartType;
  final annotations = _annotations(field.metadata);
  final config = annotations['Column'];
  final overrideType = config == null
      ? null
      : _named(config, 'type')?.toSource().split('.').last;
  final isUuid =
      annotations.containsKey('Uuid') ||
      annotations.containsKey('UuidGenerated');
  final generated = annotations.containsKey('UuidGenerated');
  var type =
      overrideType ??
      switch (baseType) {
        'String' => 'text',
        'int' => 'integer',
        'bool' => 'boolean',
        'DateTime' => 'timestamptz',
        _ => throw FormatException(
          '$name.$fieldName: specify @Column(type: ...) for $dartType.',
        ),
      };
  if (isUuid) {
    if (baseType != 'String' ||
        (overrideType != null && overrideType != 'uuid')) {
      throw FormatException(
        '$name.$fieldName: UUID requires String and SqlType.uuid.',
      );
    }
    type = 'uuid';
  }
  const compatible = {
    'text': ['String'],
    'uuid': ['String'],
    'integer': ['int'],
    'bigInteger': ['int'],
    'boolean': ['bool'],
    'numeric': ['String'],
    'date': ['DateTime'],
    'timestamp': ['DateTime'],
    'timestamptz': ['DateTime'],
    'jsonb': [
      'Map<String, Object>',
      'Map<String, Object?>',
      'Object',
      'List<Object>',
      'List<Object?>',
    ],
  };
  if (!(compatible[type]?.contains(baseType) ?? false)) {
    throw FormatException(
      '$name.$fieldName: incompatible Dart/PostgreSQL type $dartType / $type.',
    );
  }
  final varchar = annotations['VarChar'];
  var sqlType = switch (type) {
    'bigInteger' => 'bigint',
    _ => type,
  };
  if (varchar != null) {
    final length = int.tryParse(_positional(varchar).single.toSource());
    if (type != 'text' || length == null || length <= 0) {
      throw FormatException('VarChar requires String and a positive length.');
    }
    sqlType = 'varchar($length)';
  }
  final primary = annotations['PrimaryKey'];
  final identity =
      primary != null && _named(primary, 'autoIncrement')?.toSource() == 'true';
  if (identity && type != 'integer' && type != 'bigInteger') {
    throw FormatException('Identity requires INTEGER or BIGINT.');
  }
  if (generated && primary == null) {
    throw FormatException('UuidGenerated requires PrimaryKey.');
  }
  final defaultAnnotation = annotations['Default'];
  if (generated && defaultAnnotation != null ||
      identity && defaultAnnotation != null) {
    throw FormatException('Generated keys cannot also declare Default.');
  }
  final parameter = parameters[fieldName];
  final inferredDefault =
      parameter?.defaultClause?.value ?? variable.initializer;
  final defaultSql = generated
      ? 'gen_random_uuid()'
      : defaultAnnotation == null
      ? inferredDefault == null || inferredDefault is NullLiteral
            ? null
            : _literalSql(inferredDefault, type)
      : _literalSql(_positional(defaultAnnotation).single, type);
  final columnNameArg = config == null ? null : _named(config, 'name');
  final columnName = columnNameArg == null || columnNameArg is NullLiteral
      ? _snake(fieldName)
      : _string(columnNameArg);
  validateSchemaIdentifier(columnName);
  final foreign = annotations['ForeignKey'];
  final target = foreign == null
      ? null
      : _named(foreign, 'references')?.toSource();
  final created = annotations.containsKey('CreatedAt'),
      updated = annotations.containsKey('UpdatedAt'),
      deleted = annotations.containsKey('DeletedAt');
  if (deleted && !dartType.endsWith('?')) {
    throw FormatException('DeletedAt requires nullable DateTime?.');
  }
  if ((created || updated || deleted) && baseType != 'DateTime') {
    throw FormatException('Timestamp annotation requires DateTime.');
  }
  return AnalyzedField(
    fieldName,
    dartType,
    type,
    SchemaColumn(
      name: columnName,
      type: sqlType,
      nullable: primary == null && dartType.endsWith('?'),
      primaryKey: primary != null,
      identity: identity,
      unique: annotations.containsKey('Unique'),
      defaultSql: defaultSql,
    ),
    createdAt: created,
    updatedAt: updated,
    deletedAt: deleted,
    target: target,
    typeExplicit: overrideType != null || isUuid,
  );
}

/// Resolves all FK types together, including forward references and cycles.
Map<String, Annotation> _annotations(Iterable<Annotation> annotations) {
  final result = <String, Annotation>{};
  for (final annotation in annotations) {
    final name = annotation.name.toSource();
    if (!_annotationNames.contains(name)) continue;
    if (result.containsKey(name)) throw FormatException('Duplicate @$name.');
    result[name] = annotation;
  }
  return result;
}

Iterable<Expression> _positional(Annotation a) => a.arguments!.arguments
    .where((e) => e is! NamedArgument)
    .map((e) => e.argumentExpression);
Expression? _named(Annotation a, String name) => a.arguments?.arguments
    .whereType<NamedArgument>()
    .where((e) => e.name.lexeme == name)
    .firstOrNull
    ?.argumentExpression;
String _string(Expression e) => e is StringLiteral && e.stringValue != null
    ? e.stringValue!
    : throw FormatException('Expected a literal String.');
String _literalSql(Expression e, String type) {
  final numeric = double.tryParse(e.toSource());
  final compatible = e is StringLiteral
      ? {
          'text',
          'uuid',
          'numeric',
          'jsonb',
          'date',
          'timestamp',
          'timestamptz',
        }.contains(type)
      : e is BooleanLiteral
      ? type == 'boolean'
      : numeric != null &&
            numeric.isFinite &&
            {'integer', 'bigInteger', 'numeric'}.contains(type);
  if (!compatible ||
      {'integer', 'bigInteger'}.contains(type) &&
          BigInt.tryParse(e.toSource()) == null) {
    throw FormatException('Default literal is incompatible with $type.');
  }
  if (e is StringLiteral) return "'${_string(e).replaceAll("'", "''")}'";
  return e.toSource();
}
