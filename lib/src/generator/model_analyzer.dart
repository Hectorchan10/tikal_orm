import 'dart:io';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';

// Generator
import 'analysis/seeder_analyzer.dart';

// API
import 'package:tikal_orm/tikal_orm.dart';

part 'analysis/model_parser.dart';
part 'analysis/seeder_discovery.dart';
part 'analysis/model_validator.dart';
part 'analysis/field_validator.dart';
part 'analysis/index_validator.dart';
part 'analysis/type_mapper.dart';
part 'analysis/converter_analyzer.dart';
part 'emission/type_emitter.dart';
part 'analysis/relation_validator.dart';
part 'emission/relation_emitter.dart';
part 'analysis/foreign_key_resolver.dart';
part 'emission/library_emitter.dart';
part 'emission/constructor_emitter.dart';

/// Analysis output for one model. Generation never opens a database.
@internal
final class AnalyzedModel {
  AnalyzedModel(this.name, this._table, this.fields, this.constructor);
  final String name;
  final SchemaTable _table;
  SchemaTable get table => SchemaTable(
    name: _table.name,
    schema: _table.schema,
    columns: fields.map((f) => f.column),
    indexes: _table.indexes,
    uniqueConstraints: _table.uniqueConstraints,
  );
  final List<AnalyzedField> fields;
  final ConstructorDeclaration constructor;
  final List<AnalyzedRelation> relations = [];
}

/// A typed field and its inferred SQL metadata.
@internal
final class AnalyzedField {
  AnalyzedField(
    this.name,
    this.dartType,
    this.sqlType,
    this.column, {
    this.version = false,
    this.createdAt = false,
    this.updatedAt = false,
    this.deletedAt = false,
    this.target,
    this.typeExplicit = false,
    this.conversion,
    this.nativeTypes = const {},
    this.length,
    this.precision,
    this.scale,
    this.onDelete = 'noAction',
    this.onUpdate = 'noAction',
  });
  final String name, dartType, sqlType;
  SchemaColumn column;
  final bool createdAt, updatedAt, deletedAt, version;
  final bool typeExplicit;
  final AnalyzedConversion? conversion;
  final Map<String, String> nativeTypes;
  final int? length, precision, scale;
  final String onDelete, onUpdate;
  final String? target;
  AnalyzedModel? referencedModel;
  bool get nullable => dartType.endsWith('?');
  String get valueType =>
      nullable ? dartType.substring(0, dartType.length - 1) : dartType;
}

/// A constructor-only source update guarded against concurrent application edits.
@internal
typedef ConstructorUpdate = ({String original, String updated});

/// One semantic analysis session supplies both generators without resolving twice.
@internal
typedef AnalyzedProject = ({
  Map<String, List<AnalyzedModel>> models,
  List<AnalyzedSeeder> seeders,
  Map<String, ConstructorUpdate> constructors,
});

/// Stable facade over parsing, validation, relationship resolution and emission.
@internal
final class ModelAnalyzer {
  const ModelAnalyzer();
  Future<Map<String, List<AnalyzedModel>>> analyzeFiles(
    Iterable<String> paths,
  ) async => (await _parseProject(paths, const [])).models;

  /// Lightweight syntax discovery; only annotated classes need semantic seeder analysis.
  List<String> seederCandidates(Iterable<String> paths) =>
      _seederCandidates(paths);

  Future<AnalyzedProject> analyzeProject(
    Iterable<String> modelPaths,
    Iterable<String> seederPaths,
  ) => _parseProject(modelPaths, seederPaths);
  List<AnalyzedModel> analyze(String source, {String? path}) =>
      _validateModels(source, path: path);
  SchemaSnapshot schemaSnapshot(List<AnalyzedModel> models) {
    _resolveForeignKeys(models);
    return SchemaSnapshot([
      ...models.map((m) => m.table),
      ..._resolveRelations(models),
    ]);
  }

  void resolveForeignKeys(List<AnalyzedModel> models) =>
      _resolveForeignKeys(models);
  String generateLibrary(
    Map<String, List<AnalyzedModel>> byFile, {
    required String outputPath,
    List<AnalyzedSeeder> seeders = const [],
  }) => _emitLibrary(byFile, outputPath: outputPath, seeders: seeders);
}
