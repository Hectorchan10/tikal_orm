import 'dart:convert';

// Schema
import 'guards.dart';
import 'schema.dart';

// Query
import '../query/quoting.dart';

// Executor
import '../executor/query_result.dart';
import '../executor/query_executor.dart';

export 'guards.dart' show requirePostgresSchema;

/// Reads PostgreSQL catalogs. No DDL, temporary tables or schema writes occur.
final class SchemaInspector {
  const SchemaInspector(this.executor);
  final QueryExecutor executor;

  Future<SchemaSnapshot> inspect() async => (await _read()).$1;

  /// Compares managed tables only; unrelated tables are outside this snapshot.
  Future<List<String>> check(SchemaSnapshot expected) async {
    final (actual, incompatible) = await _read();
    final tables = {for (final t in actual.tables) t.key: t};
    final differences = <String>[];
    for (final table in expected.tables) {
      final found = tables[table.key];
      if (found == null) {
        differences.add('Missing table ${table.key}');
        continue;
      }
      differences.addAll(incompatible[table.key] ?? const []);
      final columns = {for (final c in found.columns) c.name: c};
      for (final column in table.columns) {
        final actual = columns[column.name];
        final path = '${table.key}.${quotedIdentifier(column.name)}';
        if (actual == null) {
          differences.add('Missing column $path');
          continue;
        }
        void compare(String field, Object? wanted, Object? got) {
          if (wanted != got) {
            differences.add('$path $field: expected $wanted, found $got');
          }
        }

        compare('type', _type(column.type), _type(actual.type));
        compare('nullable', column.nullable, actual.nullable);
        compare('primary key', column.primaryKey, actual.primaryKey);
        compare('unique', column.unique, actual.unique);
        compare('identity', column.identity, actual.identity);
        compare('foreign key', column.references, actual.references);
        compare(
          'default',
          normalizeSchemaDefault(column.defaultSql, column.type),
          normalizeSchemaDefault(actual.defaultSql, actual.type),
        );
      }
      for (final column in found.columns.where(
        (c) => !table.columns.any((e) => e.name == c.name),
      )) {
        differences.add(
          'Unexpected column ${table.key}.${quotedIdentifier(column.name)}',
        );
      }
    }
    return List.unmodifiable(differences);
  }

  Future<(SchemaSnapshot, Map<String, List<String>>)> _read() async {
    requirePostgresSchema(executor);
    final columns = await executor.query('''
SELECT n.nspname AS schema_name, c.relname AS table_name,
       a.attname AS column_name, format_type(a.atttypid, a.atttypmod) AS type,
       NOT a.attnotnull AS nullable, a.attidentity::text AS identity,
       pg_get_expr(d.adbin, d.adrelid) AS default_sql
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
WHERE c.relkind IN ('r', 'p') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp_%'
ORDER BY n.nspname, c.relname, a.attnum
''');
    final constraints = await executor.query('''
SELECT n.nspname AS schema_name, c.relname AS table_name, k.contype::text AS kind,
       k.conname AS name, k.condeferrable AS deferred, k.convalidated AS validated,
       k.confupdtype::text AS on_update, k.confdeltype::text AS on_delete, k.confmatchtype::text AS match_type,
       rn.nspname AS target_schema, rc.relname AS target_table,
       ARRAY(SELECT a.attname::text FROM unnest(k.conkey) WITH ORDINALITY x(num, ord)
             JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum = x.num ORDER BY x.ord) AS columns,
       ARRAY(SELECT a.attname::text FROM unnest(k.confkey) WITH ORDINALITY x(num, ord)
             JOIN pg_catalog.pg_attribute a ON a.attrelid = rc.oid AND a.attnum = x.num ORDER BY x.ord) AS target_columns
FROM pg_catalog.pg_constraint k
JOIN pg_catalog.pg_class c ON c.oid = k.conrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_class rc ON rc.oid = k.confrelid
LEFT JOIN pg_catalog.pg_namespace rn ON rn.oid = rc.relnamespace
WHERE k.contype IN ('p', 'u', 'f') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n.nspname, c.relname, k.conname
''');
    final constraintsByColumn = <(String, String, String), List<TikalRow>>{};
    for (final constraint in constraints.rows) {
      final schema = constraint.asString('schema_name')!;
      final table = constraint.asString('table_name')!;
      for (final column in (constraint['columns'] as List).cast<String>()) {
        (constraintsByColumn[(schema, table, column)] ??= []).add(constraint);
      }
    }
    final byTable = <(String, String), List<SchemaColumn>>{};
    final issues = <String, List<String>>{};
    String key(String schema, String table) =>
        '${quotedIdentifier(schema)}.${quotedIdentifier(table)}';
    for (final row in columns.rows) {
      final schema = row.asString('schema_name')!,
          table = row.asString('table_name')!;
      final tableKey = key(schema, table);
      final target = byTable[(schema, table)] ??= [];
      final name = row.asString('column_name');
      if (name == null) continue;
      var primary = false, unique = false;
      String? reference;
      for (final constraint
          in constraintsByColumn[(schema, table, name)] ?? const <TikalRow>[]) {
        final keys = constraint['columns'] as List;
        final kind = constraint.asString('kind');
        if (keys.length != 1 ||
            constraint['deferred'] == true ||
            constraint['validated'] != true) {
          (issues[tableKey] ??= []).add(
            'Incompatible constraint $tableKey.${constraint['name']}',
          );
          continue;
        }
        if (kind == 'p') primary = true;
        if (kind == 'u') unique = true;
        if (kind == 'f') {
          final targetKeys = (constraint['target_columns'] as List)
              .cast<String>();
          if (reference != null ||
              targetKeys.length != 1 ||
              constraint['on_update'] != 'a' ||
              constraint['on_delete'] != 'a' ||
              constraint['match_type'] != 's') {
            (issues[tableKey] ??= []).add(
              'Incompatible foreign key $tableKey.${constraint['name']}',
            );
          }
          reference =
              '${key(constraint.asString('target_schema')!, constraint.asString('target_table')!)}(${targetKeys.map(quotedIdentifier).join(', ')})';
        }
      }
      final identity = row.asString('identity') ?? '';
      if (identity == 'a') {
        (issues[tableKey] ??= []).add(
          '$tableKey.$name identity is ALWAYS; expected BY DEFAULT',
        );
      }
      target.add(
        SchemaColumn(
          name: name,
          type: _type(row.asString('type')!),
          nullable: row.asBool('nullable')!,
          primaryKey: primary,
          unique: unique,
          identity: identity.isNotEmpty,
          defaultSql: row.asString('default_sql'),
          references: reference,
        ),
      );
    }
    return (
      SchemaSnapshot([
        for (final entry in byTable.entries)
          SchemaTable(
            name: entry.key.$2,
            schema: entry.key.$1,
            columns: entry.value,
          ),
      ]),
      issues,
    );
  }
}

String _type(String type) => type
    .replaceAll('character varying', 'varchar')
    .replaceAll('timestamp with time zone', 'timestamptz')
    .replaceAll('timestamp without time zone', 'timestamp');

/// Normalizes server-added casts for scalar defaults while preserving string case.
/// Complex expressions remain exact comparisons rather than guessed equivalences.
String? normalizeSchemaDefault(String? expression, String type) {
  if (expression == null) return null;
  var value = expression.trim();
  final literal = RegExp(r"^'((?:[^']|'')*)'(?:::[a-zA-Z0-9_ .\[\]()]+)?$")
      .firstMatch(value);
  if (literal != null) {
    value = literal[1]!.replaceAll("''", "'");
    if (type == 'jsonb') {
      Object? canonical(Object? value) => value is Map
          ? {
              for (final key in value.keys.cast<String>().toList()..sort())
                key: canonical(value[key]),
            }
          : value is List
          ? value.map(canonical).toList()
          : value;
      return jsonEncode(canonical(jsonDecode(value)));
    }
    if (!{'boolean', 'numeric', 'integer', 'bigint', 'uuid'}.contains(type)) {
      return 'literal:$value';
    }
  }
  if (type == 'numeric') {
    value = value.replaceFirstMapped(RegExp(r'^(\d+)\.0+$'), (m) => m[1]!);
  }
  return value.replaceFirst(
    'pg_catalog.gen_random_uuid()',
    'gen_random_uuid()',
  );
}
