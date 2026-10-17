import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';

// Generator
import 'seeder_analyzer.dart';

// Query
import '../query/quoting.dart';

// Schema
import '../schema/schema.dart';

part 'model_parser.dart';
part 'model_validator.dart';
part 'field_validator.dart';
part 'foreign_key_resolver.dart';
part 'legacy_detector.dart';
part 'library_emitter.dart';

/// Analysis output for one model. Generation never opens a database.
final class AnalyzedModel {
  AnalyzedModel(this.name, this._table, this.fields, this.constructor);
  final String name;
  bool legacy = true;
  final SchemaTable _table;
  SchemaTable get table => SchemaTable(
    name: _table.name,
    schema: _table.schema,
    columns: fields.map((f) => f.column),
  );
  final List<AnalyzedField> fields;
  final ConstructorDeclaration constructor;
}

/// A typed field and its inferred SQL metadata.
final class AnalyzedField {
  AnalyzedField(
    this.name,
    this.dartType,
    this.sqlType,
    this.column, {
    this.createdAt = false,
    this.updatedAt = false,
    this.deletedAt = false,
    this.target,
    this.typeExplicit = false,
  });
  final String name, dartType, sqlType;
  SchemaColumn column;
  final bool createdAt, updatedAt, deletedAt;
  final bool typeExplicit;
  final String? target;
  AnalyzedModel? referencedModel;
  bool get nullable => dartType.endsWith('?');
  String get valueType =>
      nullable ? dartType.substring(0, dartType.length - 1) : dartType;
}

/// One semantic analysis session supplies both generators without resolving twice.
typedef AnalyzedProject = ({
  Map<String, List<AnalyzedModel>> models,
  List<AnalyzedSeeder> seeders,
});

/// Stable facade over parsing, validation, relationship resolution and emission.
final class ModelAnalyzer {
  const ModelAnalyzer();
  Future<Map<String, List<AnalyzedModel>>> analyzeFiles(
    Iterable<String> paths,
  ) async => (await _parseProject(paths, const [])).models;
  Future<AnalyzedProject> analyzeProject(
    Iterable<String> modelPaths,
    Iterable<String> seederPaths,
  ) => _parseProject(modelPaths, seederPaths);
  List<AnalyzedModel> analyze(String source, {String? path}) =>
      _validateModels(source, path: path);
  void resolveForeignKeys(List<AnalyzedModel> models) =>
      _resolveForeignKeys(models);
  bool ownsLegacyOutput(
    String content,
    String sourceName,
    List<AnalyzedModel> models,
  ) => _ownsLegacyOutput(content, sourceName, models);
  String generateLibrary(
    Map<String, List<AnalyzedModel>> byFile, {
    required String outputPath,
    List<AnalyzedSeeder> seeders = const [],
  }) => _emitLibrary(byFile, outputPath: outputPath, seeders: seeders);
}
