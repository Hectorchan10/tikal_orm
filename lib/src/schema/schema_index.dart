part of 'schema.dart';

/// An ordinary PostgreSQL B-tree index, distinct from a UNIQUE constraint.
final class SchemaIndex {
  /// Validates the name and preserves the ordered SQL column names.
  SchemaIndex({required this.name, required Iterable<String> columns})
    : columns = _validatedColumns(name, columns);

  /// Index identifier, unique within its PostgreSQL schema.
  final String name;

  /// SQL column names, in index order; expressions are unsupported.
  final List<String> columns;

  /// PostgreSQL CREATE INDEX statement for [table].
  String createSql(SchemaTable table) =>
      'CREATE INDEX ${quotedIdentifier(name)} ON ${table.sqlName} (${columns.map(quotedIdentifier).join(', ')})';

  /// Renders one ordinary index using the active dialect's quoting/namespace.
  String createSqlFor(SchemaTable table, SqlDialect dialect) {
    final strategy = dialect.strategy;
    return 'CREATE INDEX ${strategy.quote(name)} ON ${strategy.qualifiedName(table.name, table.schema ?? 'public')} (${columns.map(strategy.quote).join(', ')})';
  }

  /// PostgreSQL DROP INDEX statement in [table]'s schema.
  String dropSql(SchemaTable table) =>
      'DROP INDEX ${quotedIdentifier(table.schema ?? 'public')}.${quotedIdentifier(name)}';

  /// Serializes the ordered definition.
  Map<String, Object?> toJson() => {'name': name, 'columns': columns};

  /// Reconstructs a validated index definition.
  factory SchemaIndex.fromJson(Map<String, Object?> json) => SchemaIndex(
    name: json['name'] as String,
    columns: (json['columns'] as List).cast<String>(),
  );
}

/// A named, immediate PostgreSQL UNIQUE table constraint and its implicit index.
final class SchemaUniqueConstraint {
  /// Validates the name and preserves the ordered SQL column names.
  SchemaUniqueConstraint({
    required this.name,
    required Iterable<String> columns,
  }) : columns = _validatedColumns(name, columns);

  /// Constraint and backing-index identifier.
  final String name;

  /// SQL column names, in declaration order.
  final List<String> columns;

  /// Table-level constraint declaration, with quoted identifiers.
  String get declaration =>
      'CONSTRAINT ${quotedIdentifier(name)} UNIQUE (${columns.map(quotedIdentifier).join(', ')})';

  /// PostgreSQL ALTER TABLE statement adding this constraint.
  String createSql(SchemaTable table) =>
      'ALTER TABLE ${table.sqlName} ADD $declaration';

  /// PostgreSQL ALTER TABLE statement removing this constraint.
  String dropSql(SchemaTable table) =>
      'ALTER TABLE ${table.sqlName} DROP CONSTRAINT ${quotedIdentifier(name)}';

  /// Serializes the ordered definition.
  Map<String, Object?> toJson() => {'name': name, 'columns': columns};

  /// Reconstructs a validated UNIQUE constraint definition.
  factory SchemaUniqueConstraint.fromJson(Map<String, Object?> json) =>
      SchemaUniqueConstraint(
        name: json['name'] as String,
        columns: (json['columns'] as List).cast<String>(),
      );
}

List<String> _validatedColumns(String name, Iterable<String> columns) {
  validateSchemaIdentifier(name);
  final result = List<String>.unmodifiable(columns);
  if (result.isEmpty || result.toSet().length != result.length) {
    throw FormatException(
      'Index/constraint "$name" needs distinct SQL columns.',
    );
  }
  for (final column in result) {
    validateSchemaIdentifier(column);
  }
  return result;
}

/// Validates index ownership and avoids duplicate implicit/explicit indexes.
void _validateTableIndexes(SchemaTable table) {
  final known = table.columns.map((c) => c.name).toSet();
  final names = <String>{
    if (table.columns.any((c) => c.primaryKey)) '${table.name}_pkey',
    for (final c in table.columns) ...[
      if (c.unique) '${table.name}_${c.name}_key',
      if (c.references != null) '${table.name}_${c.name}_fkey',
    ],
  };
  final uniqueGroups = <Set<String>>[
    if (table.columns.any((c) => c.primaryKey))
      table.columns.where((c) => c.primaryKey).map((c) => c.name).toSet(),
    for (final c in table.columns.where((c) => c.unique)) {c.name},
  ];
  final indexGroups = <String>{
    table.columns.where((c) => c.primaryKey).map((c) => c.name).join('\u0000'),
    for (final c in table.columns.where((c) => c.unique)) c.name,
  };
  void validate(String name, List<String> columns) {
    if (!names.add(name)) {
      throw FormatException('Duplicate index/constraint name "$name".');
    }
    if (!known.containsAll(columns)) {
      throw FormatException(
        'Index/constraint "$name" references an unknown SQL column in ${table.sqlName}.',
      );
    }
  }

  for (final constraint in table.uniqueConstraints) {
    validate(constraint.name, constraint.columns);
    final group = constraint.columns.toSet();
    if (uniqueGroups.any(
      (g) => g.length == group.length && g.containsAll(group),
    )) {
      throw FormatException(
        'Redundant UNIQUE constraint "${constraint.name}".',
      );
    }
    uniqueGroups.add(group);
    indexGroups.add(constraint.columns.join('\u0000'));
  }
  for (final index in table.indexes) {
    validate(index.name, index.columns);
    if (!indexGroups.add(index.columns.join('\u0000'))) {
      throw FormatException('Redundant index "${index.name}".');
    }
  }
}

void _validateIndexNames(List<SchemaTable> tables) {
  final names = <(String, String)>{};
  void add(SchemaTable table, String name) {
    if (!names.add((table.schema ?? 'public', name))) {
      throw FormatException(
        'Duplicate relation/index name "$name" in schema ${table.schema ?? 'public'}.',
      );
    }
  }

  for (final table in tables) {
    add(table, table.name);
    if (table.columns.any((c) => c.primaryKey)) {
      add(table, '${table.name}_pkey');
    }
    for (final column in table.columns.where((c) => c.unique)) {
      add(table, '${table.name}_${column.name}_key');
    }
    for (final index in table.indexes) {
      add(table, index.name);
    }
    for (final constraint in table.uniqueConstraints) {
      add(table, constraint.name);
    }
  }
}

SchemaDiff _diffIndexes(SchemaTable? before, SchemaTable after) {
  final up = <String>[], down = <String>[];
  var review = false, destructiveDown = false;
  bool same(List<String> a, List<String> b) =>
      a.length == b.length && a.indexed.every((e) => e.$2 == b[e.$1]);
  final oldIndexes = {
    for (final i in before?.indexes ?? <SchemaIndex>[]) i.name: i,
  };
  final newIndexes = {for (final i in after.indexes) i.name: i};
  final oldUnique = {
    for (final c in before?.uniqueConstraints ?? <SchemaUniqueConstraint>[])
      c.name: c,
  };
  final newUnique = {for (final c in after.uniqueConstraints) c.name: c};
  for (final index in oldIndexes.values) {
    if (newIndexes[index.name] case final next?
        when same(next.columns, index.columns)) {
      continue;
    }
    up.add(index.dropSql(after));
    down.insert(0, index.createSql(after));
    review = true;
  }
  for (final constraint in oldUnique.values) {
    if (newUnique[constraint.name] case final next?
        when same(next.columns, constraint.columns)) {
      continue;
    }
    up.add(constraint.dropSql(after));
    down.insert(0, constraint.createSql(after));
    review = true;
  }
  for (final constraint in newUnique.values) {
    if (before == null) continue; // Already declared by CREATE TABLE.
    if (oldUnique[constraint.name] case final previous?
        when same(previous.columns, constraint.columns)) {
      continue;
    }
    up.add(constraint.createSql(after));
    down.insert(0, constraint.dropSql(after));
    review = true;
    destructiveDown = true;
  }
  for (final index in newIndexes.values) {
    if (oldIndexes[index.name] case final previous?
        when same(previous.columns, index.columns)) {
      continue;
    }
    up.add(index.createSql(after));
    if (before != null) down.insert(0, index.dropSql(after));
  }
  return SchemaDiff(
    up,
    down,
    requiresReview: review,
    destructiveDown: destructiveDown,
  );
}
