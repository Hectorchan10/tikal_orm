part of '../model_analyzer.dart';

const _constructorMarker =
    'Generated constructor. Updated by TikalORM generate.';

bool _isManagedConstructor(ConstructorDeclaration constructor) =>
    constructor.documentationComment?.tokens.any(
      (token) => token.lexeme.contains(_constructorMarker),
    ) ??
    false;

(int, int, String)? _constructorEdit(ClassDeclaration node) {
  final constructors = node.body.members
      .whereType<ConstructorDeclaration>()
      .toList();
  final existing = constructors.singleOrNull;
  final managed = existing != null && _isManagedConstructor(existing);
  if (constructors.isNotEmpty && !managed) return null;
  if (constructors.length > 1) return null;
  final parameters = <String>[];
  for (final field in node.body.members.whereType<FieldDeclaration>()) {
    if (field.isStatic || _isRelationField(field)) continue;
    for (final variable in field.fields.variables) {
      final name = variable.name.lexeme;
      final initializer = variable.initializer;
      if (initializer != null) {
        // Preserve collection and computed initializers on the field itself.
        if (initializer is SimpleStringLiteral ||
            initializer is BooleanLiteral ||
            initializer is IntegerLiteral ||
            initializer is DoubleLiteral ||
            initializer is NullLiteral) {
          parameters.add('this.$name = ${initializer.toSource()}');
        }
        continue;
      }
      final annotations = {
        for (final annotation in field.metadata)
          _annotationClass(
            annotation.elementAnnotation?.computeConstantValue(),
          ): annotation,
      };
      final defaultAnnotation = annotations['Default'];
      if (defaultAnnotation != null) {
        final value = defaultAnnotation.elementAnnotation!
            .computeConstantValue()!
            .getField('value')!;
        parameters.add('this.$name = ${_constantSource(value)}');
      } else if (annotations.containsKey('Version')) {
        parameters.add('this.$name = 1');
      } else {
        final nullable =
            variable.declaredFragment?.element.type.nullabilitySuffix ==
            NullabilitySuffix.question;
        parameters.add('${nullable ? '' : 'required '}this.$name');
      }
    }
  }
  final name = node.namePart.typeName.lexeme;
  final args = parameters.isEmpty ? '' : '{${parameters.join(', ')}}';
  final source = '/// $_constructorMarker\n$name($args);';
  if (managed) {
    final start = existing.documentationComment!.offset;
    return (start, existing.end - start, source);
  }
  return (node.body.offset + 1, 0, '\n$source\n');
}

String _applyEdits(String source, List<(int, int, String)> edits) {
  final ordered = [...edits]..sort((a, b) => b.$1.compareTo(a.$1));
  for (final edit in ordered) {
    source = source.replaceRange(edit.$1, edit.$1 + edit.$2, edit.$3);
  }
  return source;
}
