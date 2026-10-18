part of '../model_analyzer.dart';

(String, String) _mapFieldType(
  String name,
  String fieldName,
  String dartType,
  String baseType,
  String? overrideType,
  bool isUuid,
  Map<String, Annotation> annotations, {
  AnalyzedConversion? conversion,
}) {
  var type =
      conversion?.sqlType ??
      overrideType ??
      (annotations.containsKey('Decimal') ? 'numeric' : null) ??
      switch (baseType) {
        'String' => 'text',
        'int' => 'integer',
        'double' => 'doublePrecision',
        'Uint8List' => 'byteArray',
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
    'doublePrecision': ['double'],
    'byteArray': ['Uint8List'],
    'json': ['Map<String, Object?>', 'List<Object?>', 'Object'],
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
  if (conversion == null && !(compatible[type]?.contains(baseType) ?? false)) {
    throw FormatException(
      '$name.$fieldName: incompatible Dart/SQL type $dartType / $type.',
    );
  }
  if (conversion != null && overrideType != null && overrideType != type) {
    throw FormatException('Column type conflicts with converter sqlType.');
  }
  final varchar = annotations['VarChar'];
  var sqlType = switch (type) {
    'bigInteger' => 'bigint',
    'doublePrecision' => 'double precision',
    'byteArray' => 'bytea',
    _ => type,
  };
  if (varchar != null) {
    final length = int.tryParse(_positional(varchar).single.toSource());
    if (type != 'text' || length == null || length <= 0) {
      throw FormatException('VarChar requires String and a positive length.');
    }
    sqlType = 'varchar($length)';
  }
  final decimal = annotations['Decimal'];
  if (decimal != null) {
    final dimensions = _positional(decimal)
        .map((e) => int.tryParse(e.toSource()))
        .toList();
    final precision = dimensions.firstOrNull;
    final scale = dimensions.length == 2 ? dimensions[1] : null;
    if (type != 'numeric' ||
        precision == null ||
        scale == null ||
        scale < 1 ||
        scale > precision) {
      throw FormatException(
        '$name.$fieldName: Decimal requires String and 1 <= scale <= precision.',
      );
    }
    sqlType = 'numeric($precision,$scale)';
  }
  return (type, sqlType);
}
