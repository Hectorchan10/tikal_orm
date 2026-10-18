part of 'dialect.dart';

/// Shared standard SQL syntax, overridden only where an engine differs.
class PostgresDialect implements Dialect {
  /// Creates standard PostgreSQL syntax and capabilities.
  const PostgresDialect();
  @override
  int get maxParameters => 65535;
  @override
  String get writeLockClause => ' FOR UPDATE';
  @override
  void insertIgnore(SqlWriter writer, void Function() body) {
    writer.write('INSERT INTO ');
    body();
    writer.write(' ON CONFLICT DO NOTHING');
  }

  @override
  bool supports(SqlType type) => true;
  @override
  String ddlType(SqlType type, {int? length, int? precision, int? scale}) {
    _validateDimensions(length, precision, scale);
    if (length != null && type == SqlType.text) return 'varchar($length)';
    if (length != null && type == SqlType.character) {
      return 'character($length)';
    }
    if (precision != null && type == SqlType.numeric) {
      return 'numeric($precision${scale == null ? '' : ',$scale'})';
    }
    return type.sqlName;
  }

  @override
  String quote(String name) => '"${name.replaceAll('"', '""')}"';
  @override
  String placeholder(int index) => '\$$index';
  @override
  String qualifiedName(String name, String? schema) =>
      schema == null ? quote(name) : '${quote(schema)}.${quote(name)}';
  @override
  bool get supportsReturning => true;
  @override
  bool get generatesUuidOnClient => false;
  @override
  bool get supportsCaseSensitiveLike => true;
  @override
  bool get supportsPostgresSchema => true;
  @override
  String get emptyInsert => 'DEFAULT VALUES';
  @override
  String get offsetOnlyPrefix => '';
  @override
  void writeLike(
    SqlWriter writer,
    ColumnDefinition column,
    String pattern, {
    required bool caseInsensitive,
    required bool negated,
  }) {
    writer
      ..writeIdentifier(column.name)
      ..write(negated ? ' NOT' : '')
      ..write(caseInsensitive ? ' ILIKE ' : ' LIKE ');
    writer.bindTyped(column.sqlType, column.encodeValue(pattern));
    writer.write(r" ESCAPE '\'");
  }

  @override
  void writeOrderTerm(
    SqlWriter writer,
    String column, {
    required bool descending,
    NullsOrder? nulls,
  }) {
    writer
      ..writeIdentifier(column)
      ..write(descending ? ' DESC' : ' ASC');
    if (nulls != null) {
      writer.write(nulls == NullsOrder.first ? ' NULLS FIRST' : ' NULLS LAST');
    }
  }

  @override
  void upsertClause(
    SqlWriter writer,
    List<ColumnDefinition> conflicts,
    List<ColumnDefinition> updates, {
    String? primaryKey,
  }) {
    writer.write(
      ' ON CONFLICT (${conflicts.map((c) => quote(c.name)).join(', ')}) ',
    );
    writer.write(
      updates.isEmpty
          ? 'DO NOTHING'
          : 'DO UPDATE SET ${updates.map((c) => '${quote(c.name)} = EXCLUDED.${quote(c.name)}').join(', ')}',
    );
  }
}
