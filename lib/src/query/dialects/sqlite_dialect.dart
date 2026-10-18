part of 'dialect.dart';

@internal
final class SqliteDialect extends PostgresDialect {
  const SqliteDialect();
  @override
  int get maxParameters => 999;
  @override
  String get writeLockClause => '';
  @override
  void insertIgnore(SqlWriter writer, void Function() body) {
    writer.write('INSERT OR IGNORE INTO ');
    body();
  }

  @override
  bool supports(SqlType type) =>
      type != SqlType.time && type != SqlType.interval;
  @override
  String ddlType(SqlType type, {int? length, int? precision, int? scale}) {
    _validateDimensions(length, precision, scale);
    if (!supports(type)) {
      throw TikalUnsupportedException(
        'SQLite does not support ${type.sqlName}.',
      );
    }
    return switch (type) {
      SqlType.integer ||
      SqlType.smallInteger ||
      SqlType.bigInteger ||
      SqlType.boolean => 'INTEGER',
      SqlType.doublePrecision => 'REAL',
      SqlType.byteArray => 'BLOB',
      _ => 'TEXT',
    };
  }

  @override
  bool get generatesUuidOnClient => true;
  @override
  bool get supportsCaseSensitiveLike => false;
  @override
  String placeholder(int index) => '?';
  @override
  bool get supportsPostgresSchema => false;
  @override
  String qualifiedName(String name, String? schema) => quote(name);
  @override
  String get offsetOnlyPrefix => ' LIMIT -1';
  @override
  void writeLike(
    SqlWriter writer,
    ColumnDefinition column,
    String pattern, {
    required bool caseInsensitive,
    required bool negated,
  }) {
    if (!caseInsensitive) {
      throw const TikalUnsupportedException(
        'SQLite LIKE is case-insensitive for ASCII and cannot guarantee '
        'case-sensitive semantics. Use ilike(...) or a raw predicate with '
        'explicit SQLite semantics.',
      );
    }
    super.writeLike(
      writer,
      column,
      pattern,
      caseInsensitive: false,
      negated: negated,
    );
  }
}
