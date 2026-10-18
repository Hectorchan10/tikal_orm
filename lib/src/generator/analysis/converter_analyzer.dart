part of '../model_analyzer.dart';

// URIs are resolved into static imports only during emission.
String _importableType(DartType type) {
  if (type is! InterfaceType || type.element.name!.startsWith('_')) {
    throw FormatException(
      'Persistent types must be public concrete types: $type.',
    );
  }
  final originalUri = type.element.library.uri.toString();
  final uri =
      originalUri.startsWith('package:tikal_orm/src/model/') ||
          originalUri.endsWith('/mysql_types.dart')
      ? 'package:tikal_orm/tikal_orm.dart'
      : originalUri.endsWith('/postgres_types.dart')
      ? 'package:tikal_orm/postgres.dart'
      : originalUri;
  final prefix = uri == 'dart:core' ? '' : '§$uri§';
  final args = type.typeArguments.isEmpty
      ? ''
      : '<${type.typeArguments.map(_importableType).join(', ')}>';
  return '$prefix${type.element.name}$args${type.nullabilitySuffix == NullabilitySuffix.question ? '?' : ''}';
}

@internal
typedef AnalyzedConversion = ({
  String sqlType,
  String expression,
  String dartType,
});

Future<AnalyzedConversion?> _conversionFor(
  FieldDeclaration field,
  ResolvedUnitResult unit,
) async {
  final enumerated = _enumConversion(field, unit);
  if (enumerated != null) return enumerated;
  final annotations = field.metadata
      .where(
        (a) =>
            _annotationClass(a.elementAnnotation?.computeConstantValue()) ==
            'Convert',
      )
      .toList();
  if (annotations.isEmpty) return null;
  if (annotations.length != 1) throw FormatException('Duplicate @Convert.');
  final annotation = annotations.single;
  final value = annotation.elementAnnotation!.computeConstantValue()!.getField(
    'converter',
  );
  final type = value?.type;
  if (value == null || type is! InterfaceType) {
    throw FormatException(
      'Convert requires a constant TypeConverter instance.',
    );
  }
  final contract = type.allSupertypes
      .where(
        (t) =>
            t.element.name == 'TypeConverter' &&
            t.element.library.uri.path.endsWith(
              'model/conversion/type_converter.dart',
            ),
      )
      .firstOrNull;
  if (contract == null ||
      !type.element.constructors.any(
        (c) =>
            c.isConst &&
            !c.isPrivate &&
            !c.formalParameters.any((p) => p.isRequired),
      )) {
    throw FormatException(
      'Converter ${type.element.name} needs a public const constructor without required arguments.',
    );
  }
  final fieldType = field.fields.variables.first.declaredFragment!.element.type;
  final nonNull = unit.typeSystem.promoteToNonNull(fieldType);
  if (!unit.typeSystem.isAssignableTo(nonNull, contract.typeArguments[0]) ||
      !unit.typeSystem.isAssignableTo(contract.typeArguments[0], nonNull)) {
    throw FormatException(
      'Converter ${type.element.name} does not match $fieldType.',
    );
  }
  final sqlType = await _converterSqlType(value, type);
  final expression = _positional(annotation).single;
  return (
    sqlType: sqlType,
    expression: _qualifiedExpression(expression, unit.content),
    dartType: _importableType(nonNull),
  );
}

Future<String> _converterSqlType(DartObject value, InterfaceType type) async {
  DartObject? sql = _inheritedField(value, 'sqlType');
  if (sql == null) {
    final candidates = [type, ...type.allSupertypes];
    final getter = candidates
        .map((t) => t.element.getGetter('sqlType'))
        .whereType<GetterElement>()
        .firstOrNull;
    if (getter != null) {
      final library = getter.library;
      final resolved = await library.session.getResolvedLibraryByElement(
        library,
      );
      if (resolved is ResolvedLibraryResult) {
        final node = resolved
            .getFragmentDeclaration(getter.firstFragment)
            ?.node;
        final body = node is MethodDeclaration ? node.body : null;
        final expression = body is ExpressionFunctionBody
            ? body.expression
            : body is BlockFunctionBody &&
                  body.block.statements.singleOrNull is ReturnStatement
            ? (body.block.statements.single as ReturnStatement).expression
            : null;
        final element = switch (expression) {
          PrefixedIdentifier() => expression.identifier.element,
          PropertyAccess() => expression.propertyName.element,
          SimpleIdentifier() => expression.element,
          _ => null,
        };
        if (element is GetterElement) {
          sql =
              _inheritedField(value, element.variable.name!) ??
              element.variable.computeConstantValue();
        }
      }
    }
  }
  final name = sql?.getField('_name')?.toStringValue();
  if (name == null || !SqlType.values.any((t) => t.name == name)) {
    throw FormatException(
      'Converter sqlType must be a constant field or a getter returning one SqlType constant.',
    );
  }
  return name;
}

String _qualifiedExpression(Expression expression, String content) {
  final edits = <(int, int, String)>[];
  expression.accept(_ExpressionQualifier(edits));
  var source = content.substring(expression.offset, expression.end);
  edits.sort((a, b) => b.$1.compareTo(a.$1));
  for (final (offset, length, replacement) in edits) {
    source = source.replaceRange(
      offset - expression.offset,
      offset - expression.offset + length,
      replacement,
    );
  }
  return expression is InstanceCreationExpression &&
          expression.keyword?.lexeme != 'const'
      ? 'const $source'
      : source;
}

final class _ExpressionQualifier extends RecursiveAstVisitor<void> {
  _ExpressionQualifier(this.edits);
  final List<(int, int, String)> edits;
  @override
  void visitNamedType(NamedType node) {
    if (node.type case final type?) {
      edits.add((node.offset, node.length, _importableType(type)));
    }
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final element = node.identifier.element;
    if (element?.library case final library?) {
      edits.add((
        node.offset,
        node.length,
        '§${library.uri}§${element!.enclosingElement is InterfaceElement ? '${element.enclosingElement!.name}.' : ''}${element.name}',
      ));
    }
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (element is TopLevelVariableElement ||
        element is TopLevelFunctionElement ||
        element is GetterElement &&
            element.enclosingElement is LibraryElement) {
      if (element?.library case final library?) {
        edits.add((
          node.offset,
          node.length,
          '§${library.uri}§${element!.enclosingElement is InterfaceElement ? '${element.enclosingElement!.name}.' : ''}${element.name}',
        ));
      }
    }
  }
}

DartObject? _inheritedField(DartObject value, String name) {
  final field = value.getField(name);
  if (field != null) return field;
  final parent = value.getField('(super)');
  return parent == null ? null : _inheritedField(parent, name);
}

AnalyzedConversion? _enumConversion(
  FieldDeclaration field,
  ResolvedUnitResult unit,
) {
  final annotations = field.metadata
      .where(
        (a) =>
            _annotationClass(a.elementAnnotation?.computeConstantValue()) ==
            'Enumerated',
      )
      .toList();
  if (annotations.isEmpty) return null;
  if (annotations.length != 1 ||
      field.metadata.any(
        (a) =>
            _annotationClass(a.elementAnnotation?.computeConstantValue()) ==
            'Convert',
      )) {
    throw FormatException('Use exactly one Enumerated or Convert annotation.');
  }
  final type = unit.typeSystem.promoteToNonNull(
    field.fields.variables.first.declaredFragment!.element.type,
  );
  if (type is! InterfaceType || type.element is! EnumElement) {
    throw FormatException('Enumerated requires a Dart enum field.');
  }
  final mode = annotations.single.elementAnnotation!
      .computeConstantValue()!
      .getField('type')!
      .getField('_name')!
      .toStringValue();
  final dartType = _importableType(type);
  final converter = mode == 'name'
      ? 'EnumNameConverter'
      : 'EnumOrdinalConverter';
  return (
    sqlType: mode == 'name' ? 'text' : 'integer',
    expression:
        'const §package:tikal_orm/tikal_orm.dart§$converter<$dartType>($dartType.values)',
    dartType: dartType,
  );
}
