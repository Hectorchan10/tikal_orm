import 'dart:convert';

// SQL
import '../sql/sql_type.dart';
import '../query/sql/quoting.dart';

// Query
import '../query/dialects/dialect.dart';

// Database
import '../database/query_executor.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Model
import '../model/metadata/table_definition.dart';
import '../model/metadata/column_definition.dart';

part 'schema_index.dart';
part 'portable_ddl.dart';

/// A serializable schema snapshot produced from annotated models.
final class SchemaSnapshot {
  /// Creates a snapshot with immutable tables; duplicate table keys throw FormatException.
  SchemaSnapshot(Iterable<SchemaTable> tables)
    : tables = List.unmodifiable(tables) {
    if (this.tables.map((t) => t.key).toSet().length != this.tables.length) {
      throw FormatException('Duplicate table in schema snapshot.');
    }
    _validateIndexNames(this.tables);
  }

  /// Immutable table definitions in snapshot order.
  final List<SchemaTable> tables;

  /// Renders explicit creation DDL, including indexes and foreign keys.
  /// Runtime [definitions] preserve native overrides absent from snapshot JSON.
  /// Foreign keys are inline on SQLite and added after tables on PostgreSQL/MySQL,
  /// so mutually referencing tables need no implicit catalog reads or ordering.
  /// Throws [TikalUnsupportedException] for unrepresentable types/defaults/identity.
  /// Does not inspect, execute, reconcile or migrate an existing database.
  List<String> createSqlFor(
    SqlDialect dialect, {
    Iterable<TableDefinition<Object>> definitions = const [],
  }) => _createStatements(this, dialect, definitions);

  /// Returns the versioned JSON representation used by migration tooling.
  Map<String, Object?> toJson() => {
    'version': 1,
    'tables': tables.map((t) => t.toJson()).toList(),
  };

  /// Reconstructs and validates the serialized representation.
  /// Malformed fields or unsupported snapshot versions are rejected.
  factory SchemaSnapshot.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw FormatException('Unsupported schema snapshot version');
    }
    return SchemaSnapshot(
      (json['tables'] as List).map(
        (t) => SchemaTable.fromJson((t as Map).cast<String, Object?>()),
      ),
    );
  }
}

/// Table schema, independent of model construction and database access.
final class SchemaTable {
  /// Creates immutable PostgreSQL schema metadata and validates identifiers.
  /// Duplicate columns or invalid identifiers throw FormatException.
  SchemaTable({
    required this.name,
    this.schema,
    required Iterable<SchemaColumn> columns,
    Iterable<SchemaIndex> indexes = const [],
    Iterable<SchemaUniqueConstraint> uniqueConstraints = const [],
  }) : columns = List.unmodifiable(columns),
       indexes = List.unmodifiable(indexes),
       uniqueConstraints = List.unmodifiable(uniqueConstraints) {
    validateSchemaIdentifier(name);
    validateSchemaIdentifier(schema ?? 'public');
    if (this.columns.map((c) => c.name).toSet().length != this.columns.length) {
      throw FormatException('Duplicate column in $sqlName.');
    }
    for (final c in this.columns) {
      validateSchemaIdentifier(c.name);
    }
    _validateTableIndexes(this);
  }

  /// Database identifier without SQL quotes.
  final String name;

  /// Optional namespace; PostgreSQL uses schemas, MySQL uses databases, and SQLite ignores it.
  final String? schema;

  /// Immutable column definitions in schema declaration order.
  final List<SchemaColumn> columns;

  /// Ordinary indexes, separate from implicit primary/unique indexes.
  final List<SchemaIndex> indexes;

  /// Named table-level UNIQUE constraints, each owning its backing index.
  final List<SchemaUniqueConstraint> uniqueConstraints;

  /// Quoted schema-qualified table identifier used when comparing snapshots.
  String get key => sqlName;

  /// Quoted PostgreSQL table identifier, including its schema.
  String get sqlName =>
      '${quotedIdentifier(schema ?? 'public')}.${quotedIdentifier(name)}';

  /// PostgreSQL CREATE TABLE statement; it is never executed automatically.
  String get createSql {
    final keys = columns.where((c) => c.primaryKey).toList();
    final declarations = columns
        .map((c) => c.declaration(inlinePrimaryKey: keys.length <= 1))
        .toList();
    if (keys.length > 1) {
      declarations.add(
        'PRIMARY KEY (${keys.map((c) => quotedIdentifier(c.name)).join(', ')})',
      );
    }
    declarations.addAll(uniqueConstraints.map((c) => c.declaration));
    return 'CREATE TABLE $sqlName (${declarations.join(', ')})';
  }

  /// Renders one explicit CREATE TABLE, with inline foreign keys and constraints.
  /// Indexes are separate statements: use [SchemaSnapshot.createSqlFor] for a plan.
  /// Supply [columnDefinitions] to retain native overrides and binding types that
  /// snapshot JSON does not preserve. Unknown PostgreSQL-only DDL is rejected.
  /// Throws [TikalUnsupportedException] for unsupported types/defaults/identity.
  /// This helper never executes SQL; [createSql] remains PostgreSQL migration DDL.
  String createSqlFor(
    SqlDialect dialect, {
    Iterable<ColumnDefinition> columnDefinitions = const [],
  }) => _createTable(this, dialect, columnDefinitions, foreignKeys: true);

  /// Returns the versioned JSON representation used by migration tooling.
  Map<String, Object?> toJson() => {
    'name': name,
    'schema': schema,
    'columns': columns.map((c) => c.toJson()).toList(),
    if (indexes.isNotEmpty) 'indexes': indexes.map((i) => i.toJson()).toList(),
    if (uniqueConstraints.isNotEmpty)
      'uniqueConstraints': uniqueConstraints.map((c) => c.toJson()).toList(),
  };

  /// Reconstructs and validates the serialized representation.
  /// Malformed field types are rejected.
  factory SchemaTable.fromJson(Map<String, Object?> j) => SchemaTable(
    name: j['name'] as String,
    schema: j['schema'] as String?,
    indexes: (j['indexes'] as List? ?? const []).map(
      (i) => SchemaIndex.fromJson((i as Map).cast<String, Object?>()),
    ),
    uniqueConstraints: (j['uniqueConstraints'] as List? ?? const []).map(
      (c) =>
          SchemaUniqueConstraint.fromJson((c as Map).cast<String, Object?>()),
    ),
    columns: (j['columns'] as List).map(
      (c) => SchemaColumn.fromJson((c as Map).cast<String, Object?>()),
    ),
  );
}

/// The exact SQL declaration and constraints for one generated column.
final class SchemaColumn {
  /// Describes a PostgreSQL column declaration, including its structural constraints.
  const SchemaColumn({
    required this.name,
    required this.type,
    required this.nullable,
    this.primaryKey = false,
    this.unique = false,
    this.identity = false,
    this.defaultSql,
    this.references,
  });

  /// Database identifier without SQL quotes.
  final String name;

  /// PostgreSQL type declaration stored in the snapshot, for example varchar(255).
  final String type;

  /// Whether the column accepts SQL NULL.
  final bool nullable;

  /// Whether the column participates in the table primary key.
  final bool primaryKey;

  /// Whether the column has a single-column uniqueness constraint.
  final bool unique;

  /// Whether PostgreSQL supplies a numeric identity value.
  final bool identity;

  /// Reviewed SQL default expression, or null when no server default exists.
  final String? defaultSql;

  /// Quoted qualified table and quoted referenced column, e.g. "public"."users"("id").
  final String? references;

  /// Quoted PostgreSQL column declaration and its inline constraints.
  String get sql => declaration();

  /// Renders a column, optionally leaving the primary key to a table constraint.
  String declaration({bool inlinePrimaryKey = true}) =>
      '${quotedIdentifier(name)} $type${identity ? ' GENERATED BY DEFAULT AS IDENTITY' : ''}${primaryKey && inlinePrimaryKey
          ? ' PRIMARY KEY'
          : nullable && !primaryKey
          ? ''
          : ' NOT NULL'}${unique ? ' UNIQUE' : ''}${defaultSql == null ? '' : ' DEFAULT $defaultSql'}';

  /// Returns the versioned JSON representation used by migration tooling.
  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'nullable': nullable,
    'primaryKey': primaryKey,
    'unique': unique,
    'identity': identity,
    'default': defaultSql,
    'references': references,
  };

  /// Reconstructs and validates the serialized representation.
  /// Malformed field types are rejected.
  factory SchemaColumn.fromJson(Map<String, Object?> j) => SchemaColumn(
    name: j['name'] as String,
    type: j['type'] as String,
    nullable: j['nullable'] as bool,
    primaryKey: j['primaryKey'] as bool,
    unique: j['unique'] as bool,
    identity: j['identity'] as bool,
    defaultSql: j['default'] as String?,
    references: j['references'] as String?,
  );

  /// Whether the serialized structural properties of both columns match exactly.
  bool sameAs(SchemaColumn other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

/// Reviewable ordered operations; generated index/constraint drops carry safety flags.
final class SchemaDiff {
  /// Creates immutable forward and rollback operations with review/safety flags.
  SchemaDiff(
    Iterable<String> up,
    Iterable<String> down, {
    this.requiresReview = false,
    this.destructiveDown = false,
  }) : up = List.unmodifiable(up),
       down = List.unmodifiable(down);

  /// Ordered forward SQL operations.
  final List<String> up;

  /// Ordered rollback SQL operations.
  final List<String> down;

  /// Whether forward SQL requires review and explicit unsafe-change permission.
  final bool requiresReview;

  /// Whether rollback drops data, schema objects or a uniqueness guarantee.
  final bool destructiveDown;
}

/// Compares snapshots, refusing inferred table/column deletes and renames.
final class SchemaDiffer {
  /// Creates a conservative differ with reviewed index/UNIQUE replacement support.
  const SchemaDiffer();

  /// Compares managed PostgreSQL snapshots and returns reviewable DDL.
  /// Throws StateError for removals, renames, key changes or unsafe type conversions.
  /// Only integer/varchar widening is inferred; live schema reconciliation never runs.
  /// Index removals/rebuilds and UNIQUE changes set the review flag.
  SchemaDiff compare(SchemaSnapshot before, SchemaSnapshot after) {
    final old = {for (final t in before.tables) t.key: t};
    final current = {for (final t in after.tables) t.key: t};
    if (old.keys.any((k) => !current.containsKey(k))) {
      throw StateError(
        'Table removal or rename requires an explicit manual migration.',
      );
    }
    final up = <String>[],
        down = <String>[],
        foreignKeys = <String>[],
        foreignDown = <String>[];
    var review = false, destructive = false, irreversible = false;
    for (final table in after.tables) {
      final previous = old[table.key];
      if (previous == null) {
        up.add(table.createSql);
        down.insert(0, 'DROP TABLE ${table.sqlName}');
        destructive = true;
      } else {
        final oldKeys = previous.columns
            .where((c) => c.primaryKey)
            .map((c) => c.name)
            .join(',');
        final newKeys = table.columns
            .where((c) => c.primaryKey)
            .map((c) => c.name)
            .join(',');
        if (oldKeys != newKeys) {
          throw StateError(
            'Primary key changes require an explicit manual migration.',
          );
        }
        final columns = {for (final c in previous.columns) c.name: c};
        if (columns.keys.any((n) => !table.columns.any((c) => c.name == n))) {
          throw StateError(
            'Column removal or rename in ${table.key} requires an explicit manual migration.',
          );
        }
        for (final c in table.columns) {
          final p = columns[c.name];
          final prefix = 'ALTER TABLE ${table.sqlName}';
          final column = quotedIdentifier(c.name);
          if (p == null) {
            up.add('$prefix ADD COLUMN ${c.sql}');
            down.insert(0, '$prefix DROP COLUMN $column');
            destructive = true;
            review |= !c.nullable && c.defaultSql == null;
          } else if (!c.sameAs(p)) {
            if (c.primaryKey != p.primaryKey || c.identity != p.identity) {
              throw StateError(
                'Constraint change on ${table.key}.${c.name} requires an explicit manual migration.',
              );
            }
            if (c.type != p.type) {
              if (c.primaryKey || !_safeWidening(p.type, c.type)) {
                throw StateError(
                  'Type change ${table.key}.${c.name}: ${p.type} -> ${c.type} requires an explicit manual migration with a reviewed USING/backfill strategy.',
                );
              }
              up.add('$prefix ALTER COLUMN $column TYPE ${c.type}');
              review = true;
              irreversible = true;
            }
            if (c.nullable != p.nullable) {
              up.add(
                '$prefix ALTER COLUMN $column ${c.nullable ? 'DROP' : 'SET'} NOT NULL',
              );
              review |= !c.nullable;
              irreversible = true;
            }
            if (c.defaultSql != p.defaultSql) {
              up.add(
                '$prefix ALTER COLUMN $column ${c.defaultSql == null ? 'DROP DEFAULT' : 'SET DEFAULT ${c.defaultSql}'}',
              );
              down.insert(
                0,
                '$prefix ALTER COLUMN $column ${p.defaultSql == null ? 'DROP DEFAULT' : 'SET DEFAULT ${p.defaultSql}'}',
              );
            }
            if (c.unique != p.unique) {
              final constraint = quotedIdentifier(
                '${table.name}_${c.name}_key',
              );
              up.add(
                c.unique
                    ? '$prefix ADD CONSTRAINT $constraint UNIQUE ($column)'
                    : '$prefix DROP CONSTRAINT $constraint',
              );
              review = true;
              irreversible = true;
            }
            if (c.references != p.references) {
              final constraint = quotedIdentifier(
                '${table.name}_${c.name}_fkey',
              );
              if (p.references != null) {
                up.add('$prefix DROP CONSTRAINT $constraint');
              }
              if (c.references != null) {
                foreignKeys.add(
                  '$prefix ADD CONSTRAINT $constraint FOREIGN KEY ($column) REFERENCES ${c.references}',
                );
              }
              review = true;
              irreversible = true;
            }
          }
        }
      }
      final indexDiff = _diffIndexes(previous, table);
      up.addAll(indexDiff.up);
      down.insertAll(0, indexDiff.down);
      review |= indexDiff.requiresReview;
      destructive |= indexDiff.destructiveDown;
      for (final c in table.columns) {
        if (c.references != null &&
            (previous == null ||
                !previous.columns.any((p) => p.name == c.name))) {
          final constraint = quotedIdentifier('${table.name}_${c.name}_fkey');
          foreignKeys.add(
            'ALTER TABLE ${table.sqlName} ADD CONSTRAINT $constraint FOREIGN KEY (${quotedIdentifier(c.name)}) REFERENCES ${c.references}',
          );
          foreignDown.insert(
            0,
            'ALTER TABLE ${table.sqlName} DROP CONSTRAINT $constraint',
          );
        }
      }
    }
    up.addAll(foreignKeys);
    return SchemaDiff(
      up,
      irreversible ? <String>[] : [...foreignDown, ...down],
      requiresReview: review,
      destructiveDown: destructive,
    );
  }
}

/// Enforces PostgreSQL's identifier length before it can silently truncate names.
void validateSchemaIdentifier(String name) {
  if (name.isEmpty ||
      name.contains('\u0000') ||
      utf8.encode(name).length > 63) {
    throw FormatException(
      'PostgreSQL identifiers require 1–63 bytes and no NUL.',
    );
  }
}

bool _safeWidening(String before, String after) {
  if (before == 'integer' && after == 'bigint') return true;
  final oldLength = RegExp(r'^varchar\((\d+)\)$').firstMatch(before);
  final newLength = RegExp(r'^varchar\((\d+)\)$').firstMatch(after);
  return oldLength != null &&
      (after == 'text' ||
          newLength != null &&
              int.parse(newLength[1]!) >= int.parse(oldLength[1]!));
}
