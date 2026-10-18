import 'dart:convert';

// Schema
import 'guards.dart';
import 'schema.dart';

// SQL
import '../query/sql/quoting.dart';

// Database
import '../database/query_result.dart';
import '../database/query_executor.dart';

export 'guards.dart' show requirePostgresSchema;

/// Reads PostgreSQL catalogs. No DDL, temporary tables or schema writes occur.
final class SchemaInspector {
  /// Reads PostgreSQL catalogs through the supplied executor without writing schema.
  const SchemaInspector(this.executor);

  /// Executor used only for read-only PostgreSQL catalog queries.
  final QueryExecutor executor;

  /// Returns the catalog snapshot for supported PostgreSQL tables and constraints.
  /// Throws TikalUnsupportedException for other engines; driver failures propagate.
  Future<SchemaSnapshot> inspect() async => (await _read()).$1;

  /// Compares managed tables only; unrelated tables are outside this snapshot.
  Future<List<String>> check(SchemaSnapshot expected) async {
    final (actual, incompatible) = await _read(expected: expected);
    final tables = {for (final t in actual.tables) t.key: t};
    final differences = <String>[];
    for (final table in expected.tables) {
      final found = tables[table.key];
      if (found == null) {
        differences.add('Missing table ${table.key}');
        continue;
      }
      differences.addAll(incompatible[table.key] ?? const []);
      void compareDefinitions(
        String kind,
        Map<String, Object?> wanted,
        Map<String, Object?> actual,
      ) {
        for (final name in {...wanted.keys, ...actual.keys}) {
          if (jsonEncode(wanted[name]) != jsonEncode(actual[name])) {
            differences.add(
              '${table.key} $kind "$name": expected ${wanted[name]}, found ${actual[name]}',
            );
          }
        }
      }

      compareDefinitions(
        'index',
        {for (final i in table.indexes) i.name: i.columns},
        {for (final i in found.indexes) i.name: i.columns},
      );
      compareDefinitions(
        'UNIQUE constraint',
        {for (final c in table.uniqueConstraints) c.name: c.columns},
        {for (final c in found.uniqueConstraints) c.name: c.columns},
      );
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

  Future<(SchemaSnapshot, Map<String, List<String>>)> _read({
    SchemaSnapshot? expected,
  }) async {
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
       pg_get_constraintdef(k.oid) AS definition,
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
    final indexes = await executor.query('''
SELECT n.nspname AS schema_name, c.relname AS table_name, ic.relname AS name,
       (am.amname = 'btree' AND NOT i.indisunique AND i.indisvalid AND i.indisready
        AND i.indpred IS NULL AND i.indexprs IS NULL AND i.indnkeyatts = i.indnatts
        AND NOT EXISTS (SELECT 1 FROM unnest(i.indoption) opt WHERE opt <> 0)
        AND NOT EXISTS (
          SELECT 1 FROM unnest(i.indclass) op
          JOIN pg_catalog.pg_opclass opc ON opc.oid = op WHERE NOT opc.opcdefault)
        AND NOT EXISTS (
          SELECT 1 FROM unnest(i.indkey, i.indcollation) x(num, coll)
          JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum = x.num
          WHERE x.coll <> a.attcollation)) AS supported,
       ARRAY(SELECT a.attname::text FROM unnest(i.indkey) WITH ORDINALITY x(num, ord)
             JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum = x.num ORDER BY x.ord) AS columns
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
JOIN pg_catalog.pg_am am ON am.oid = ic.relam
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint k WHERE k.conindid = i.indexrelid)
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp_%'
ORDER BY n.nspname, c.relname, ic.relname
''');
    final constraintsByColumn = <(String, String, String), List<TikalRow>>{};
    for (final constraint in constraints.rows) {
      final schema = constraint.asString('schema_name')!;
      final table = constraint.asString('table_name')!;
      for (final column in (constraint['columns'] as List).cast<String>()) {
        (constraintsByColumn[(schema, table, column)] ??= []).add(constraint);
      }
    }
    final issues = <String, List<String>>{};
    String key(String schema, String table) =>
        '${quotedIdentifier(schema)}.${quotedIdentifier(table)}';
    final rejected = <(String, String, String)>{};
    final uniqueGroups = <(String, String), List<Set<String>>>{};
    for (final constraint in constraints.rows) {
      final schema = constraint.asString('schema_name')!;
      final table = constraint.asString('table_name')!;
      final keys = (constraint['columns'] as List).cast<String>();
      if (constraint['kind'] == 'p' ||
          constraint['kind'] == 'u' &&
              keys.length == 1 &&
              constraint['name'] == '${table}_${keys.single}_key') {
        (uniqueGroups[(schema, table)] ??= []).add(keys.toSet());
      }
    }
    final uniqueByTable = <(String, String), List<SchemaUniqueConstraint>>{};
    for (final constraint in constraints.rows) {
      if (constraint.asString('kind') != 'u') continue;
      final table = constraint.asString('table_name')!;
      final schema = constraint.asString('schema_name')!;
      final keys = (constraint['columns'] as List).cast<String>();
      final name = constraint.asString('name')!;
      final explicitlyNamed =
          expected?.tables.any(
            (t) =>
                t.name == table &&
                (t.schema ?? 'public') == schema &&
                t.uniqueConstraints.any((c) => c.name == name),
          ) ??
          false;
      if (keys.length == 1 &&
          name == '${table}_${keys.single}_key' &&
          !explicitlyNamed) {
        continue;
      }
      if (_unsupportedConstraint(constraint)) continue;
      final groups = uniqueGroups[(schema, table)] ??= [];
      final group = keys.toSet();
      // The conventional single-column name is already represented above.
      final conventional =
          keys.length == 1 && name == '${table}_${keys.single}_key';
      if (!conventional &&
          groups.any((g) => g.length == group.length && g.containsAll(group))) {
        rejected.add((schema, table, name));
        (issues[key(schema, table)] ??= []).add(
          'Redundant UNIQUE constraint ${key(schema, table)}.$name',
        );
        continue;
      }
      if (!conventional) groups.add(group);
      (uniqueByTable[(schema, table)] ??= []).add(
        SchemaUniqueConstraint(name: name, columns: keys),
      );
    }
    final byTable = <(String, String), List<SchemaColumn>>{};
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
        if (rejected.contains((schema, table, constraint.asString('name')!))) {
          continue;
        }
        if (kind == 'u' &&
            uniqueByTable[(schema, table)]?.any(
                  (c) => c.name == constraint['name'],
                ) ==
                true) {
          continue;
        }
        if ((keys.length != 1 && kind != 'p') ||
            _unsupportedConstraint(constraint)) {
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
              !const {'a', 'r', 'c', 'n'}.contains(constraint['on_update']) ||
              !const {'a', 'r', 'c', 'n'}.contains(constraint['on_delete']) ||
              constraint['match_type'] != 's') {
            (issues[tableKey] ??= []).add(
              'Incompatible foreign key $tableKey.${constraint['name']}',
            );
          }
          reference =
              '${key(constraint.asString('target_schema')!, constraint.asString('target_table')!)}(${targetKeys.map(quotedIdentifier).join(', ')})${_catalogAction('DELETE', constraint['on_delete'])}${_catalogAction('UPDATE', constraint['on_update'])}';
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
    final indexesByTable = <(String, String), List<SchemaIndex>>{};
    for (final index in indexes.rows) {
      final schema = index.asString('schema_name')!;
      final table = index.asString('table_name')!;
      if (index['supported'] != true) {
        (issues[key(schema, table)] ??= []).add(
          'Incompatible index ${key(schema, table)}.${index['name']}',
        );
        continue;
      }
      final group = (index['columns'] as List).cast<String>().join('\u0000');
      final implicit = <String>{
        (byTable[(schema, table)] ?? const <SchemaColumn>[])
            .where((c) => c.primaryKey)
            .map((c) => c.name)
            .join('\u0000'),
        for (final c in byTable[(schema, table)] ?? const <SchemaColumn>[])
          if (c.unique) c.name,
        for (final c
            in uniqueByTable[(schema, table)] ??
                const <SchemaUniqueConstraint>[])
          c.columns.join('\u0000'),
        for (final i
            in indexesByTable[(schema, table)] ?? const <SchemaIndex>[])
          i.columns.join('\u0000'),
      };
      if (implicit.contains(group)) {
        (issues[key(schema, table)] ??= []).add(
          'Redundant index ${key(schema, table)}.${index['name']}',
        );
        continue;
      }
      (indexesByTable[(schema, table)] ??= []).add(
        SchemaIndex(
          name: index.asString('name')!,
          columns: (index['columns'] as List).cast<String>(),
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
            indexes: indexesByTable[entry.key] ?? const [],
            uniqueConstraints: uniqueByTable[entry.key] ?? const [],
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

String _catalogAction(String operation, Object? code) {
  const actions = {'c': 'CASCADE', 'n': 'SET NULL', 'r': 'RESTRICT'};
  return actions.containsKey(code) ? ' ON $operation ${actions[code]}' : '';
}

bool _unsupportedConstraint(TikalRow constraint) =>
    constraint['deferred'] == true ||
    constraint['validated'] != true ||
    constraint.hasColumn('definition') &&
        (constraint.asString('definition')?.contains('NULLS NOT DISTINCT') ??
            false);
