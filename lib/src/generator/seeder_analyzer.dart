import 'dart:io';
import 'dart:convert';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';

part 'seeder_emitter.dart';

/// Validated input for static callback emission; no runtime analyzer dependency.
final class AnalyzedSeeder {
  const AnalyzedSeeder(
    this.id,
    this.name,
    this.path,
    this.constructor,
    this.hasRun,
    this.calls,
  );
  final String id, name, path, constructor;
  final bool hasRun;
  final List<String> calls;
}

final class SeederAnalyzer {
  const SeederAnalyzer();

  Future<List<AnalyzedSeeder>> analyzeFiles(Iterable<String> paths) async {
    final files =
        paths
            .map((p) => File(p).absolute.uri.normalizePath().toFilePath())
            .toSet()
            .toList()
          ..sort();
    if (files.isEmpty) return [];
    final contexts = AnalysisContextCollection(includedPaths: files);
    final units = <ResolvedUnitResult>[];
    try {
      for (final path in files) {
        final result = await contexts
            .contextFor(path)
            .currentSession
            .getResolvedUnit(path);
        if (result is! ResolvedUnitResult) {
          throw FormatException('Cannot resolve seeders in $path.');
        }
        units.add(result);
      }
      return analyzeUnits(units);
    } finally {
      await contexts.dispose();
    }
  }

  /// Reuses resolved libraries supplied by the model generator's analysis session.
  List<AnalyzedSeeder> analyzeUnits(Iterable<ResolvedUnitResult> units) {
    final seeders = <AnalyzedSeeder>[];
    for (final result in units) {
      final path = result.path;
      for (final node
          in result.unit.declarations.whereType<ClassDeclaration>()) {
        for (final annotation in node.metadata) {
          final metadata = annotation.elementAnnotation;
          final value = metadata?.computeConstantValue();
          final type =
              value?.type ??
              switch (metadata?.element) {
                ConstructorElement(:final enclosingElement) =>
                  enclosingElement.thisType,
                GetterElement(:final returnType) => returnType,
                _ => null,
              };
          if (type is! InterfaceType ||
              type.element.name != 'Seeder' ||
              !type.element.library.uri.path.endsWith('/seeding/seeder.dart')) {
            continue;
          }
          if (value == null ||
              (metadata?.constantEvaluationErrors?.isNotEmpty ?? false)) {
            throw FormatException('$path: invalid @Seeder arguments.');
          }
          final element = node.declaredFragment!.element;
          if (seeders.any((s) => s.id == _id(element))) {
            throw FormatException(
              '${element.name}: duplicate @Seeder annotation.',
            );
          }
          if (!element.isPublic ||
              element.isAbstract ||
              element.typeParameters.isNotEmpty) {
            throw FormatException(
              '${element.name}: seeder must be public, concrete and non-generic.',
            );
          }
          final constructors = element.constructors
              .where(
                (c) =>
                    c.isPublic &&
                    c.isGenerative &&
                    !c.formalParameters.any((p) => p.isRequired),
              )
              .toList();
          final unnamed = constructors
              .where((c) => c.isDefaultConstructor)
              .firstOrNull;
          final constructor =
              unnamed ??
              (constructors.length == 1 ? constructors.single : null);
          if (constructor == null) {
            throw FormatException(
              '${element.name}: seeder needs an unambiguous public generative constructor callable without arguments.',
            );
          }
          final calls = value.getField('calls')?.toListValue();
          if (calls == null) {
            throw FormatException(
              '${element.name}: calls must be a constant list of seeder types.',
            );
          }
          final targets = <String>[];
          for (final call in calls) {
            final target = call.toTypeValue();
            if (target is! InterfaceType) {
              throw FormatException(
                '${element.name}: calls must reference seeder classes.',
              );
            }
            targets.add(_id(target.element));
          }
          final method =
              element.getMethod('run') ??
              element.lookUpMethod(name: 'run', library: element.library);
          final returns = method?.returnType;
          if (method == null
              ? targets.isEmpty
              : method.isStatic ||
                    method.isAbstract ||
                    method.formalParameters.isNotEmpty ||
                    method.typeParameters.isNotEmpty ||
                    returns is! InterfaceType ||
                    !returns.isDartAsyncFuture ||
                    returns.nullabilitySuffix != NullabilitySuffix.none ||
                    returns.typeArguments.single is! VoidType) {
            throw FormatException(
              '${element.name}: seeder requires Future<void> run(), or calls-only delegation.',
            );
          }
          final suffix = constructor.isDefaultConstructor
              ? ''
              : '.${constructor.name}';
          seeders.add(
            AnalyzedSeeder(
              _id(element),
              element.name!,
              element.library.firstFragment.source.fullName,
              suffix,
              method != null,
              List.unmodifiable(targets),
            ),
          );
        }
      }
    }
    _validateGraph(seeders);
    return List.unmodifiable(seeders);
  }

  String generateRegistry(
    List<AnalyzedSeeder> seeders,
    Map<String, String> aliases,
  ) => _emitSeeders(seeders, aliases);
}

String _id(InterfaceElement element) =>
    '${element.library.uri}#${element.name}';

void _validateGraph(List<AnalyzedSeeder> seeders) {
  final names = <String>{};
  final byId = {for (final seeder in seeders) seeder.id: seeder};
  for (final seeder in seeders) {
    if (!names.add(seeder.name)) {
      throw FormatException('Duplicate seeder name: ${seeder.name}.');
    }
    for (final target in seeder.calls) {
      if (!byId.containsKey(target)) {
        throw FormatException(
          '${seeder.name}: calls references an undiscovered or unannotated seeder: $target.',
        );
      }
    }
  }
  final done = <String>{};
  final active = <String>[];
  void visit(String id) {
    if (active.contains(id)) {
      throw FormatException(
        'Circular seeder dependency: ${[...active, id].map((key) => byId[key]!.name).join(' -> ')}.',
      );
    }
    if (done.contains(id)) return;
    active.add(id);
    for (final dependency in byId[id]!.calls) {
      visit(dependency);
    }
    active.removeLast();
    done.add(id);
  }

  for (final seeder in seeders) {
    visit(seeder.id);
  }
}
