import 'dart:typed_data';

import 'package:postgres/postgres.dart' as pg;

// SQL
import '../sql_type.dart';
import '../sql_param.dart';
import 'native_sql_value.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

/// Translates [param] into the typed representation expected by the PostgreSQL driver.
Object? postgresDriverValue(SqlParam param) {
  final native = param.value;
  if (native is NativeSqlValue) {
    return switch (native.type) {
      PostgresValueType.inet => pg.TypedValue(
        pg.Type.text,
        native.value as String?,
      ),
      PostgresValueType.textArray => pg.TypedValue(
        pg.Type.textArray,
        native.value as List<String>?,
      ),
      PostgresValueType.integerArray => pg.TypedValue(
        pg.Type.integerArray,
        native.value as List<int>?,
      ),
    };
  }
  final type = switch (param.type) {
    SqlType.text => pg.Type.text,
    SqlType.character => pg.Type.character,
    SqlType.integer => pg.Type.integer,
    SqlType.smallInteger => pg.Type.smallInteger,
    SqlType.bigInteger => pg.Type.bigInteger,
    SqlType.doublePrecision => pg.Type.double,
    SqlType.numeric => pg.Type.numeric,
    SqlType.boolean => pg.Type.boolean,
    SqlType.timestamp => pg.Type.timestamp,
    SqlType.timestamptz => pg.Type.timestampTz,
    SqlType.date => pg.Type.date,
    SqlType.time => pg.Type.time,
    SqlType.interval => pg.Type.interval,
    SqlType.json => pg.Type.json,
    SqlType.jsonb => pg.Type.jsonb,
    SqlType.uuid => pg.Type.uuid,
    SqlType.byteArray => pg.Type.byteArray,
  };
  final value = param.value;
  return pg.TypedValue(type, switch (param.type) {
    SqlType.text || SqlType.character || SqlType.uuid => value as String?,
    SqlType.integer ||
    SqlType.smallInteger ||
    SqlType.bigInteger => value as int?,
    SqlType.doublePrecision => value as double?,
    SqlType.boolean => value as bool?,
    SqlType.timestamp || SqlType.date => value as DateTime?,
    SqlType.timestamptz => (value as DateTime?)?.toUtc(),
    SqlType.time => value as pg.Time?,
    SqlType.interval => value as pg.Interval?,
    SqlType.byteArray => switch (value) {
      null => null,
      Uint8List() => value,
      List<int>() => Uint8List.fromList(value),
      _ => throw TikalParameterException(
        'bytea parameters must be a List<int>, got ${value.runtimeType}.',
      ),
    },
    SqlType.numeric || SqlType.json || SqlType.jsonb => value,
  });
}

/// Translates a user supplied parameter into the representation the PostgreSQL driver
/// expects, inferring types for plain Dart values.
///
/// [position] is used to build helpful error messages.
Object? bindParameter(Object? value, {int? position}) {
  if (value is SqlParam) {
    try {
      return postgresDriverValue(value);
    } on TypeError catch (error) {
      throw TikalParameterException(
        'Value of type ${value.value.runtimeType} is not valid for SQL type ${value.type.sqlName}.',
        position: position,
        value: value.value,
        cause: error,
      );
    }
  }

  try {
    if (value == null) {
      throw TikalParameterException(
        'Cannot bind an untyped NULL parameter. '
        'Use SqlParam.nullOf(SqlType.<type>) so PostgreSQL knows the type.',
        position: position,
      );
    }
    final type = SqlType.infer(value);
    if (type == null) {
      throw TikalParameterException(
        'Unsupported parameter type ${value.runtimeType}. '
        'Pass a bool, int, double, String, DateTime, List<int> or wrap the '
        'value in SqlParam.of(...) to choose the PostgreSQL type explicitly.',
        position: position,
        value: value,
      );
    }
    return postgresDriverValue(SqlParam(type, value));
  } on TypeError catch (error) {
    throw TikalParameterException(
      'Could not bind parameter of type ${value.runtimeType}.',
      position: position,
      value: value,
      cause: error,
    );
  }
}
