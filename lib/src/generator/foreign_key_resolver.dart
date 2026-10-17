part of 'model_analyzer.dart';

void _resolveForeignKeys(List<AnalyzedModel> models) {
  final byName = {for (final m in models) m.name: m};
  if (byName.length != models.length) {
    throw FormatException('Annotated model names must be unique.');
  }
  if (models.map((m) => m.table.key).toSet().length != models.length) {
    throw FormatException('Duplicate annotated table.');
  }
  for (final model in models) {
    for (final f in model.fields.where((f) => f.target != null)) {
      final target = byName[f.target!.split('.').last];
      if (target == null) {
        throw FormatException('Unknown ForeignKey model ${f.target}.');
      }
      f.referencedModel = target;
      final key = target.fields.singleWhere((f) => f.column.primaryKey).column;
      final column = f.column;
      final inferUuid =
          key.type == 'uuid' &&
          f.valueType == 'String' &&
          f.sqlType == 'text' &&
          !f.typeExplicit;
      if (!inferUuid && column.type != key.type) {
        throw FormatException(
          '${model.name}.${f.name}: foreign key type differs from ${f.target}.',
        );
      }
      f.column = SchemaColumn(
        name: column.name,
        type: inferUuid ? 'uuid' : column.type,
        nullable: column.nullable,
        primaryKey: column.primaryKey,
        unique: column.unique,
        identity: column.identity,
        defaultSql: column.defaultSql,
        references: '${target.table.sqlName}(${quotedIdentifier(key.name)})',
      );
    }
  }
}
