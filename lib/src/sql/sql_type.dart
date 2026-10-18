/// SQL types that TikalORM can bind explicitly.
///
/// TikalORM infers a type for most Dart values automatically (see
/// `SqlParam`), but explicit typing is required for `NULL` parameters and
/// recommended when a Dart value could map to more than one column type
/// (`String` into `uuid`, `jsonb`, `numeric`, ...). The names mirror
/// PostgreSQL's types; SQLite and MySQL bind their supported equivalent values.
enum SqlType {
  /// Variable length text, `text`.
  text('text'),

  /// Fixed length character type, `char` / `bpchar`.
  character('character'),

  /// 4-byte integer, `integer`.
  integer('integer'),

  /// 2-byte integer, `smallint`.
  smallInteger('smallint'),

  /// 8-byte integer, `bigint`.
  bigInteger('bigint'),

  /// 8-byte floating point, `double precision`.
  doublePrecision('double precision'),

  /// Arbitrary precision number, `numeric`.
  numeric('numeric'),

  /// Boolean, `boolean`.
  boolean('boolean'),

  /// Timestamp without time zone, `timestamp`.
  timestamp('timestamp'),

  /// Timestamp with time zone, `timestamptz`.
  timestamptz('timestamptz'),

  /// Calendar date, `date`.
  date('date'),

  /// Time of day, `time`.
  time('time'),

  /// Time interval, `interval`.
  interval('interval'),

  /// JSON document, `json`.
  json('json'),

  /// Binary JSON document, `jsonb`.
  jsonb('jsonb'),

  /// Universally unique identifier, `uuid`.
  uuid('uuid'),

  /// Binary data, `bytea`.
  byteArray('bytea');

  const SqlType(this.sqlName);

  /// The name PostgreSQL uses for this type, as accepted by a cast.
  final String sqlName;

  /// Infers the [SqlType] TikalORM binds for [value], or `null` when the value
  /// has no direct mapping and must be wrapped in a `SqlParam`.
  ///
  /// `int` values that fit in 4 bytes become [integer] so that comparisons keep
  /// using the column index; larger values become [bigInteger].
  static SqlType? infer(Object value) => switch (value) {
    bool() => SqlType.boolean,
    int() =>
      value >= _minInt32 && value <= _maxInt32
          ? SqlType.integer
          : SqlType.bigInteger,
    double() => SqlType.doublePrecision,
    String() => SqlType.text,
    DateTime() => SqlType.timestamptz,
    List<int>() => SqlType.byteArray,
    _ => null,
  };

  static const int _minInt32 = -2147483648;
  static const int _maxInt32 = 2147483647;
}
