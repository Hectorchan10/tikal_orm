part of 'dialect.dart';

@internal
final class MysqlDialect extends PostgresDialect {
  const MysqlDialect();
  @override
  void insertIgnore(SqlWriter writer, void Function() body) {
    writer.write('INSERT IGNORE INTO ');
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
        'MySQL does not support ${type.sqlName}.',
      );
    }
    return switch (type) {
      SqlType.text => length == null ? 'TEXT' : 'VARCHAR($length)',
      SqlType.character => 'CHAR(${length ?? 1})',
      SqlType.uuid => 'CHAR(36)',
      SqlType.timestamp || SqlType.timestamptz => 'DATETIME(6)',
      SqlType.json || SqlType.jsonb => 'JSON',
      SqlType.byteArray => 'BLOB',
      SqlType.doublePrecision => 'DOUBLE',
      SqlType.numeric =>
        precision == null
            ? 'DECIMAL'
            : 'DECIMAL($precision${scale == null ? '' : ',$scale'})',
      _ => type.sqlName.toUpperCase(),
    };
  }

  @override
  bool get generatesUuidOnClient => true;
  @override
  String quote(String name) => '`${name.replaceAll('`', '``')}`';
  @override
  String placeholder(int index) => '?';
  @override
  bool get supportsPostgresSchema => false;
  @override
  String qualifiedName(String name, String? schema) =>
      super.qualifiedName(name, schema == 'public' ? null : schema);
  @override
  bool get supportsReturning => false;
  @override
  String get emptyInsert => '() VALUES ()';
  @override
  String get offsetOnlyPrefix => ' LIMIT 18446744073709551615';
  @override
  void writeLike(
    SqlWriter writer,
    ColumnDefinition column,
    String pattern, {
    required bool caseInsensitive,
    required bool negated,
  }) {
    if (!caseInsensitive) writer.write('BINARY ');
    writer
      ..writeIdentifier(column.name)
      ..write(negated ? ' NOT' : '')
      ..write(' LIKE ');
    writer.bindTyped(column.sqlType, column.encodeValue(pattern));
    writer.write(r" ESCAPE '\\'");
  }

  @override
  void writeOrderTerm(
    SqlWriter writer,
    String column, {
    required bool descending,
    NullsOrder? nulls,
  }) {
    if (nulls != null) {
      writer
        ..writeIdentifier(column)
        ..write(
          nulls == NullsOrder.first ? ' IS NULL DESC, ' : ' IS NULL ASC, ',
        );
    }
    super.writeOrderTerm(writer, column, descending: descending);
  }

  @override
  void upsertClause(
    SqlWriter writer,
    List<ColumnDefinition> conflicts,
    List<ColumnDefinition> updates, {
    String? primaryKey,
  }) {
    writer.write(' ON DUPLICATE KEY UPDATE ');
    writer.write(
      updates.isEmpty
          ? '${quote(primaryKey!)} = ${quote(primaryKey)}'
          : updates
                .map((c) => '${quote(c.name)} = VALUES(${quote(c.name)})')
                .join(', '),
    );
  }
}
