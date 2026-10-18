part of '../model_analyzer.dart';

String _emitRelations(
  AnalyzedModel model,
  Map<AnalyzedModel, String> names,
  _EmissionTypes types,
) {
  final out = StringBuffer();
  final sourceName = names[model]!;
  for (final relation in model.relations) {
    final target = relation.target!;
    final targetName = names[target]!;
    final key = model.fields.singleWhere((f) => f.column.primaryKey);
    if (relation.belongsTo) {
      final foreign = relation.foreignKey!;
      final targetKey = target.fields.singleWhere((f) => f.column.primaryKey);
      out.writeln(
        '/// Explicit singular loader for ${relation.name}.\nstatic final ${relation.name}Relation = orm.BelongsToRelation<$sourceName, $targetName, ${types.valueType(foreign)}>(foreignKey: ${foreign.name}, targetKey: ${target.name}_.${targetKey.name}, target: ${target.name}_.table);',
      );
    } else if (!relation.manyToMany) {
      out.writeln(
        '/// Explicit batch loader for ${relation.name}.\nstatic final ${relation.name}Relation = orm.${relation.oneToOne ? 'OneToOneRelation' : 'HasManyRelation'}<$sourceName, $targetName, ${types.valueType(key)}>(sourceKey: ${key.name}, foreignKey: ${target.name}_.${relation.foreignKey!.name}, target: ${target.name}_.table);',
      );
    } else {
      out.writeln(
        '/// Explicit batch loader for ${relation.name}.\nstatic final ${relation.name}Relation = orm.ManyToManyRelation<$sourceName, $targetName>(source: table, target: ${target.name}_.table, joinTable: ${_dartLiteral(relation.joinTable!)}, joinColumn: ${_dartLiteral(relation.joinColumn!)}, inverseJoinColumn: ${_dartLiteral(relation.inverseJoinColumn!)}, schema: ${_dartLiteral((relation.inverse ? target : model).table.schema ?? 'public')}, writable: ${!relation.inverse});',
      );
      out.writeln(
        '/// Explicit join-table writer for ${relation.name}.\nstatic orm.ManyToManyHandle<$sourceName, $targetName> ${relation.name}($sourceName model, {orm.QueryExecutor? executor, int batchSize = 1000}) => orm.ManyToManyHandle(relation: ${relation.name}Relation, source: model, executor: executor ?? Tikal.model<$sourceName>().executor, batchSize: batchSize);',
      );
    }
  }
  return out.toString();
}

String _emitLoadedRelations(
  AnalyzedModel model,
  Map<AnalyzedModel, String> names,
) {
  if (model.relations.isEmpty) return '';
  final out = StringBuffer(
    '/// Accessors for explicitly loaded ${model.name} collections.\n'
    'extension ${model.name}LoadedRelations on orm.LoadedRelations<${names[model]}> {\n',
  );
  for (final relation in model.relations) {
    out.writeln(
      '/// Returns the loaded ${relation.name}; throws orm.TikalModelException if omitted.\n'
      '${relation.singular ? '${names[relation.target!]}?' : 'List<${names[relation.target!]}>'} ${relation.name}For(${names[model]} model) => related(${model.name}_.${relation.name}Relation, model);',
    );
  }
  out.writeln('}');
  return out.toString();
}
