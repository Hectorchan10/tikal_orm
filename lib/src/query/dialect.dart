// Query
import 'order_by.dart';
import 'sql_writer.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';

// Model
import '../model/column_definition.dart';

/// SQL syntax and capabilities of one implemented engine.
abstract interface class Dialect {
  String quote(String name);
  String placeholder(int index);
  String qualifiedName(String name, String? schema);
  bool get supportsReturning;
  bool get supportsPostgresSchema;
  String get emptyInsert;
  String get offsetOnlyPrefix;
  void writeLike(
    SqlWriter writer,
    ColumnDefinition column,
    String pattern, {
    required bool caseInsensitive,
    required bool negated,
  });
  void writeOrderTerm(
    SqlWriter writer,
    String column, {
    required bool descending,
    NullsOrder? nulls,
  });
  void upsertClause(
    SqlWriter writer,
    List<ColumnDefinition> conflicts,
    List<ColumnDefinition> updates, {
    String? primaryKey,
  });
}

/// Compatibility enum adapters are centralized here.
extension SqlDialectStrategy on SqlDialect {
  Dialect get strategy => switch (this) {
    SqlDialect.postgres => const PostgresDialect(),
    SqlDialect.sqlite => const SqliteDialect(),
    SqlDialect.mysql => const MysqlDialect(),
  };
}

/// Shared standard SQL syntax, overridden only where an engine differs.
class PostgresDialect implements Dialect {
  const PostgresDialect();
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
    writer.bindTyped(column.sqlType, pattern);
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

final class SqliteDialect extends PostgresDialect {
  const SqliteDialect();
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

final class MysqlDialect extends PostgresDialect {
  const MysqlDialect();
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
    writer.bindTyped(column.sqlType, pattern);
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
