part of '../model_analyzer.dart';

@internal
final class AnalyzedRelation {
  AnalyzedRelation(
    this.name,
    this.targetName, {
    required this.manyToMany,
    this.mappedBy,
    this.belongsTo = false,
    this.oneToOne = false,
    this.foreignKeyName,
    this.joinTable,
    this.joinColumn,
    this.inverseJoinColumn,
  }) : explicitJoin =
           joinTable != null || joinColumn != null || inverseJoinColumn != null;
  final String name, targetName;
  final bool manyToMany, belongsTo, oneToOne;
  final String? foreignKeyName;
  bool get singular => belongsTo || oneToOne;
  final bool explicitJoin;
  final String? mappedBy;
  String? joinTable, joinColumn, inverseJoinColumn;
  AnalyzedModel? target;
  AnalyzedField? foreignKey;
  bool get inverse => mappedBy != null && manyToMany;
}

bool _isRelationField(FieldDeclaration field) => field.metadata.any(
  (a) => const {
    'HasMany',
    'ManyToMany',
    'BelongsTo',
    'OneToOne',
  }.contains(a.name.toSource().split('.').last),
);

AnalyzedRelation _analyzeRelation(
  FieldDeclaration field,
  Map<String?, FormalParameter> parameters,
) {
  final annotations = _annotations(field.metadata);
  final kinds = ['ManyToMany', 'HasMany', 'BelongsTo', 'OneToOne'];
  final selected = kinds.where(annotations.containsKey).toList();
  if (selected.length != 1 || field.fields.variables.length != 1) {
    throw FormatException('Declare exactly one relation annotation per field.');
  }
  if (annotations.keys.any((a) => !kinds.contains(a))) {
    throw FormatException('Relation fields cannot declare column annotations.');
  }
  final kind = selected.single;
  final singular = kind == 'BelongsTo' || kind == 'OneToOne';
  final annotation = annotations[kind]!;
  final variable = field.fields.variables.single;
  final name = variable.name.lexeme;
  if (name.startsWith('_')) throw FormatException('Relations must be public.');
  final target = _positional(annotation).single.toSource();
  final targetType = target.split('.').last;
  final expected = singular ? '$targetType?' : 'List<$targetType>';
  final type = field.fields.type?.toSource().replaceAll(' ', '');
  if (type != expected) throw FormatException('$name must be $expected.');
  final parameter = parameters[name];
  if (parameter?.isRequired == true ||
      (!singular &&
          variable.initializer == null &&
          parameter?.defaultClause == null)) {
    throw FormatException(
      '$name needs a default; relations are not loaded implicitly.',
    );
  }
  String? option(String key) {
    final value = _named(annotation, key);
    return value == null || value is NullLiteral ? null : _string(value);
  }

  return AnalyzedRelation(
    name,
    target.split('.').last,
    manyToMany: kind == 'ManyToMany',
    belongsTo: kind == 'BelongsTo',
    oneToOne: kind == 'OneToOne',
    foreignKeyName: option('foreignKey'),
    mappedBy: option('mappedBy'),
    joinTable: option('joinTable'),
    joinColumn: option('joinColumn'),
    inverseJoinColumn: option('inverseJoinColumn'),
  );
}

List<SchemaTable> _resolveRelations(List<AnalyzedModel> models) {
  final byName = {for (final m in models) m.name: m};
  final bridges = <String, SchemaTable>{};
  final tables = models.map((m) => m.table.key).toSet();
  for (final model in models) {
    final names = {
      ...model.fields.map((f) => f.name),
      ...model.relations.map((r) => r.name),
    };
    for (final relation in model.relations) {
      if (names.contains('${relation.name}Relation') ||
          {'table', 'repository'}.contains(relation.name)) {
        throw FormatException(
          'Generated relation accessor collision: ${model.name}.${relation.name}.',
        );
      }
      final target = byName[relation.targetName];
      if (target == null) {
        throw FormatException(
          'Unknown annotated target ${relation.targetName}.',
        );
      }
      relation.target = target;
      if (model.fields.where((f) => f.column.primaryKey).length != 1 ||
          target.fields.where((f) => f.column.primaryKey).length != 1) {
        throw FormatException(
          'Relations require simple primary keys on both sides.',
        );
      }
      if (relation.belongsTo) {
        final foreign = model.fields
            .where((f) => f.name == relation.foreignKeyName)
            .firstOrNull;
        if (foreign == null || foreign.referencedModel != target) {
          throw FormatException(
            '${model.name}.${relation.name}: foreignKey must name a local Dart foreign-key field pointing to ${target.name}.',
          );
        }
        relation.foreignKey = foreign;
      } else if (!relation.manyToMany) {
        final foreign = target.fields
            .where((f) => f.name == relation.mappedBy)
            .firstOrNull;
        if (foreign == null || foreign.referencedModel != model) {
          throw FormatException(
            '${model.name}.${relation.name}: mappedBy must name a foreign key back to ${model.name}.',
          );
        }
        if (relation.oneToOne &&
            !foreign.column.unique &&
            !foreign.column.primaryKey &&
            !target.table.uniqueConstraints.any(
              (c) =>
                  c.columns.length == 1 &&
                  c.columns.single == foreign.column.name,
            )) {
          throw FormatException(
            '${model.name}.${relation.name}: OneToOne requires a unique target foreign key.',
          );
        }
        relation.foreignKey = foreign;
      } else if (!relation.inverse) {
        final sourceKey = model.fields.singleWhere((f) => f.column.primaryKey);
        final targetKey = target.fields.singleWhere((f) => f.column.primaryKey);
        relation.joinTable ??= '${model.table.name}_${target.table.name}';
        relation.joinColumn ??=
            '${_snake(model.name)}_${sourceKey.column.name}';
        relation.inverseJoinColumn ??=
            '${_snake(target.name)}_${targetKey.column.name}';
        if (relation.joinColumn == relation.inverseJoinColumn) {
          throw FormatException('Join columns must be distinct.');
        }
        for (final name in [
          relation.joinTable!,
          relation.joinColumn!,
          relation.inverseJoinColumn!,
          '${relation.joinTable}_pkey',
          '${relation.joinTable}_${relation.joinColumn}_fkey',
          '${relation.joinTable}_${relation.inverseJoinColumn}_fkey',
        ]) {
          validateSchemaIdentifier(name);
        }
        SchemaColumn keyColumn(
          String name,
          AnalyzedModel table,
          AnalyzedField key,
        ) => SchemaColumn(
          name: name,
          type: key.column.type,
          nullable: false,
          primaryKey: true,
          references:
              '${table.table.sqlName}(${quotedIdentifier(key.column.name)}) ON DELETE CASCADE',
        );
        final bridge = SchemaTable(
          name: relation.joinTable!,
          schema: model.table.schema,
          columns: [
            keyColumn(relation.joinColumn!, model, sourceKey),
            keyColumn(relation.inverseJoinColumn!, target, targetKey),
          ],
        );
        if (tables.contains(bridge.key) || bridges.containsKey(bridge.key)) {
          throw FormatException(
            'Duplicate join table ${bridge.key}; use mappedBy for the inverse side.',
          );
        }
        bridges[bridge.key] = bridge;
      } else if (relation.explicitJoin) {
        throw FormatException(
          'An inverse relation cannot declare join metadata.',
        );
      }
    }
  }
  for (final model in models) {
    for (final relation in model.relations.where((r) => r.inverse)) {
      final owner = relation.target!.relations
          .where((r) => r.name == relation.mappedBy)
          .firstOrNull;
      if (owner == null ||
          !owner.manyToMany ||
          owner.inverse ||
          owner.target != model) {
        throw FormatException(
          '${model.name}.${relation.name}: mappedBy must name an owning many-to-many relation.',
        );
      }
      relation.joinTable = owner.joinTable;
      relation.joinColumn = owner.inverseJoinColumn;
      relation.inverseJoinColumn = owner.joinColumn;
    }
  }
  return bridges.values.toList();
}
