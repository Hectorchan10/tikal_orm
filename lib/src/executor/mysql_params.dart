import 'package:meta/meta.dart';

// Config
import '../config/sql_type.dart';

// Params
import '../params/portable_params.dart';

/// Translates a Dart value or SqlParam into the driver's portable representation.
@internal
Object? mysqlParameter(Object? value, [int? position]) =>
    encodePortableParameter(
      value,
      engine: 'MySQL',
      position: position,
      dateTime: _mysqlDate,
    );

DateTime _mysqlDate(SqlType? type, DateTime value) {
  final utc = value.toUtc();
  return type == SqlType.date
      ? DateTime.utc(utc.year, utc.month, utc.day)
      : utc;
}
