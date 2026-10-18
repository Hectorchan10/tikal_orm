import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

// SQL
import '../sql_type.dart';
import '../sql_param.dart';
import '../postgres/native_sql_value.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

/// Shared SQLite/MySQL values; engines supply only their date representation.
@internal
Object? encodePortableParameter(
  Object? value, {
  required String engine,
  required Object Function(SqlType? type, DateTime value) dateTime,
  int? position,
}) {
  if (value is NativeSqlValue ||
      value is SqlParam && value.value is NativeSqlValue) {
    throw TikalUnsupportedException(
      '$engine does not support PostgreSQL native bindings.',
    );
  }
  if (value is SqlParam) {
    try {
      final v = value.value;
      if (v == null) return null;
      return switch ((value.type, v)) {
        (SqlType.text || SqlType.character || SqlType.uuid, final String v) =>
          v,
        (
          SqlType.smallInteger || SqlType.integer || SqlType.bigInteger,
          final int v,
        ) =>
          v,
        (SqlType.doublePrecision, final num v) => v.toDouble(),
        (SqlType.numeric, final num v) => v,
        (SqlType.numeric, final String v) => v,
        (SqlType.boolean, final bool v) => v,
        (SqlType.boolean, 0 || 1) => v == 1,
        (
          SqlType.timestamp || SqlType.timestamptz || SqlType.date,
          final DateTime v,
        ) =>
          dateTime(value.type, v),
        (SqlType.json || SqlType.jsonb, _) => jsonEncode(v),
        (SqlType.byteArray, final Uint8List v) => v,
        (SqlType.byteArray, final List<int> v) => Uint8List.fromList(v),
        (SqlType.time || SqlType.interval, _) =>
          throw TikalUnsupportedException(
            '$engine does not support ${value.type.sqlName} parameters.',
          ),
        _ => throw TikalParameterException(
          '$engine cannot bind a ${v.runtimeType} as ${value.type.sqlName}.',
          position: position,
          value: v,
        ),
      };
    } on TikalException {
      rethrow;
    } on Object catch (error) {
      throw TikalParameterException(
        'Value of type ${value.value.runtimeType} is not valid for SQL type ${value.type.sqlName}.',
        position: position,
        value: value.value,
        cause: error,
      );
    }
  }
  return switch (value) {
    null => throw TikalParameterException(
      'Cannot bind an untyped NULL parameter. Use SqlParam.nullOf(SqlType.<type>) so the type is explicit.',
      position: position,
    ),
    bool() || int() || double() || String() => value,
    final DateTime v => dateTime(null, v),
    final Uint8List v => v,
    final List<int> v => Uint8List.fromList(v),
    _ => throw TikalParameterException(
      'Unsupported parameter type ${value.runtimeType}. Pass a bool, int, double, String, DateTime, List<int> or wrap the value in SqlParam.of(...) to choose the type explicitly.',
      position: position,
      value: value,
    ),
  };
}
