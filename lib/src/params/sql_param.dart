// Config
import '../config/sql_type.dart';

/// A SQL parameter with an explicit SQL type.
///
/// Plain Dart values (`bool`, `int`, `double`, `String`, `DateTime`, byte
/// lists) are typed automatically, but some cases need to be explicit:
///
/// * `NULL` parameters, which would otherwise be untyped:
///   `SqlParam.nullOf(SqlType.timestamptz)`
/// * values that are ambiguous in Dart: an identifier that must be sent as
///   `uuid` or a document that must be sent as `jsonb`:
///   `SqlParam.uuid(id)`, `SqlParam.jsonb(payload)`
///
/// ```dart
/// await db.query(
///   'SELECT * FROM users WHERE deleted_at IS NULL AND id = @id',
///   parameters: [SqlParam.uuid(userId)],
/// );
/// ```
final class SqlParam {
  /// Binds [value] as [type].
  const SqlParam(this.type, this.value);

  /// Binds an explicit SQL `NULL` of [type].
  const SqlParam.nullOf(SqlType type) : this(type, null);

  /// Binds [value] as [type]; the escape hatch for types without a named
  /// constructor.
  static SqlParam of(SqlType type, Object? value) => SqlParam(type, value);

  /// Binds [value] as `text`.
  const SqlParam.text(String? value) : this(SqlType.text, value);

  /// Binds [value] as `character`.
  const SqlParam.character(String? value) : this(SqlType.character, value);

  /// Binds [value] as `smallint`.
  const SqlParam.smallInteger(int? value) : this(SqlType.smallInteger, value);

  /// Binds [value] as `integer`.
  const SqlParam.integer(int? value) : this(SqlType.integer, value);

  /// Binds [value] as `bigint`.
  const SqlParam.bigInteger(int? value) : this(SqlType.bigInteger, value);

  /// Binds [value] as `double precision`.
  const SqlParam.doublePrecision(double? value)
    : this(SqlType.doublePrecision, value);

  /// Binds [value] as `numeric`.
  ///
  /// Accepts an [int], a [double] or a [String] such as `'12.34'`, which keeps
  /// arbitrary precision.
  const SqlParam.numeric(Object? value) : this(SqlType.numeric, value);

  /// Binds [value] as `boolean`.
  const SqlParam.boolean(bool? value) : this(SqlType.boolean, value);

  /// Binds [value] as `timestamp` without time zone.
  const SqlParam.timestamp(DateTime? value) : this(SqlType.timestamp, value);

  /// Binds [value] as `timestamptz`.
  const SqlParam.timestamptz(DateTime? value)
    : this(SqlType.timestamptz, value);

  /// Binds [value] as `date`.
  const SqlParam.date(DateTime? value) : this(SqlType.date, value);

  /// Binds [value] as `json`.
  const SqlParam.json(Object? value) : this(SqlType.json, value);

  /// Binds [value] as `jsonb`.
  const SqlParam.jsonb(Object? value) : this(SqlType.jsonb, value);

  /// Binds [value] as `uuid`.
  const SqlParam.uuid(String? value) : this(SqlType.uuid, value);

  /// Binds [value] as `bytea`.
  const SqlParam.bytes(List<int>? value) : this(SqlType.byteArray, value);

  /// Explicit SQL type of this parameter.
  final SqlType type;

  /// The Dart value to send, already in its final representation.
  final Object? value;

  @override
  String toString() => 'SqlParam(${type.sqlName}, $value)';
}
