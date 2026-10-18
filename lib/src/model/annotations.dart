// SQL
import '../sql/sql_type.dart';

// Model
import 'conversion/type_converter.dart';

/// Names the database table represented by a model.
final class TikalTable {
  /// Marks the class as persistent and supplies its database table name.
  const TikalTable(this.name, {this.schema});

  /// Database identifier without SQL quotes.
  final String name;

  /// Optional namespace; PostgreSQL uses schemas, MySQL uses databases, and SQLite ignores it.
  final String? schema;
}

/// Overrides a field's column name or engine-neutral SQL type.
final class Column {
  /// Overrides the inferred column name or engine-neutral SQL type.
  const Column({this.name, this.type});

  /// Database identifier without SQL quotes.
  final String? name;

  /// Explicit SQL type; null preserves the type inferred from the Dart field.
  final SqlType? type;
}

/// Marks a primary-key member, optionally a numeric identity.
final class PrimaryKey {
  /// Marks a primary key, optionally generated as a numeric identity.
  const PrimaryKey({this.autoIncrement = false});

  /// Whether the engine generates the numeric key during insertion.
  final bool autoIncrement;
}

/// Stores a String UUID using the selected engine's UUID representation.
final class Uuid {
  /// Maps this String field to the UUID SQL type.
  const Uuid();
}

/// Generates a String UUID on the PostgreSQL server or on the SQLite/MySQL client.
final class UuidGenerated {
  /// Uses a PostgreSQL server UUID default or a client-generated UUID v4 on SQLite/MySQL.
  const UuidGenerated();
}

/// Adds a single-column unique constraint.
final class Unique {
  /// Requests a unique constraint on this column in generated schema metadata.
  const Unique();
}

/// Declares an ordinary B-tree index on Dart field names, in the given order.
/// Repeat this annotation for multiple indexes. Schema tooling is PostgreSQL-only.
final class Index {
  /// Declares a named index; expressions and implicit-index duplicates are rejected.
  const Index({required this.name, required this.columns});

  /// PostgreSQL index identifier, unique within its schema.
  final String name;

  /// Dart field names (resolved to SQL column names), preserving composite index order.
  final List<String> columns;
}

/// Declares a named table-level UNIQUE constraint and its implicit backing index.
/// Repeat this annotation for multiple constraints; use Dart field names.
final class UniqueConstraint {
  /// Declares an immediate, non-deferrable uniqueness constraint.
  const UniqueConstraint({required this.name, required this.columns});

  /// PostgreSQL constraint and backing-index identifier.
  final String name;

  /// Dart field names (resolved to SQL column names), in declaration order.
  final List<String> columns;
}

/// Limits a String column's length.
final class VarChar {
  /// Limits this text field to the specified positive number of characters.
  const VarChar(this.length);

  /// Maximum character length of the generated varchar column.
  final int length;
}

/// Declares a literal SQL default (String, bool, int or finite double).
final class Default {
  /// Declares a literal SQL default in generated schema metadata.
  const Default(this.value);

  /// Literal value used to generate the server-side default expression.
  final Object value;
}

/// Enables the repository's creation timestamp support.
final class CreatedAt {
  /// Enables automatic insertion timestamps for this column.
  const CreatedAt();
}

/// Enables the repository's update timestamp support.
final class UpdatedAt {
  /// Enables automatic timestamps on effective single-model and bulk updates.
  const UpdatedAt();
}

/// Declares a foreign key to another annotated model's primary key.
final class ForeignKey {
  /// References the primary key of another annotated model.
  const ForeignKey({
    required this.references,
    this.onDelete = ReferentialAction.noAction,
    this.onUpdate = ReferentialAction.noAction,
  });

  /// Action applied when the referenced row is deleted.
  final ReferentialAction onDelete;

  /// Action applied when the referenced key is updated.
  final ReferentialAction onUpdate;

  /// Referenced annotated model type, resolved during static generation.
  final Type references;
}

/// Enables repository soft deletes for this nullable DateTime column.
final class DeletedAt {
  /// Marks a nullable timestamp as the soft-delete column.
  const DeletedAt();
}

/// Declares an exact decimal stored as a Dart String.
/// Generation rejects dimensions unless 1 <= scale <= precision.
final class Decimal {
  /// Declares numeric precision and fractional scale without changing binding.
  const Decimal(this.precision, this.scale);

  /// Maximum total decimal digits.
  final int precision;

  /// Maximum fractional decimal digits, at least one.
  final int scale;
}

/// Uses a constant converter for this field's binding, decoding and snapshots.
final class Convert {
  /// Selects a converter with a const constructor without required arguments.
  const Convert(this.converter);

  /// Constant converter instance, resolved statically by the generator.
  final TypeConverter<Object?, Object?> converter;
}

/// How a Dart enum is represented in SQL.
enum EnumType {
  /// Store the stable textual enum name.
  name,

  /// Store the declaration index; enum reordering requires a data migration.
  ordinal,
}

/// Converts a Dart enum using its statically generated values list.
final class Enumerated {
  /// Selects enum-name or enum-ordinal storage.
  const Enumerated(this.type);

  /// Storage representation to generate.
  final EnumType type;
}

/// Opt-in native DDL overrides; SQL parameter binding remains unchanged.
/// Missing engines fall back to their dialect's portable DDL mapping.
final class DbType {
  /// Supplies reviewed type declarations; never pass untrusted SQL here.
  const DbType({this.postgres, this.mysql, this.sqlite});

  /// Optional PostgreSQL type declaration.
  final String? postgres;

  /// Optional MySQL/MariaDB type declaration.
  final String? mysql;

  /// Optional SQLite type declaration.
  final String? sqlite;
}

/// Explicit database behavior when a referenced row changes.
enum ReferentialAction {
  /// Reject a violating change at the constraint's normal check time.
  noAction('NO ACTION'),

  /// Propagate deletion or key updates to dependent rows.
  cascade('CASCADE'),

  /// Replace the dependent foreign key with NULL.
  setNull('SET NULL'),

  /// Reject the referenced change immediately.
  restrict('RESTRICT');

  const ReferentialAction(this.sql);

  /// Standard SQL action used in schema declarations.
  final String sql;
}

/// Declares an explicit many-to-many relation without a join-table model.
/// Lists retain constructor defaults; use withRelations to load related rows.
final class ManyToMany {
  /// Declares an owning relation, or a read-only inverse using mappedBy.
  const ManyToMany(
    this.target, {
    this.joinTable,
    this.joinColumn,
    this.inverseJoinColumn,
    this.mappedBy,
  });

  /// Annotated target model type.
  final Type target;

  /// Owning join-table name; omit on the inverse side.
  final String? joinTable;

  /// Join column referencing the owning model's key.
  final String? joinColumn;

  /// Join column referencing the target model's key.
  final String? inverseJoinColumn;

  /// Owning relation field on the target, for a read-only inverse.
  final String? mappedBy;
}

/// Declares explicit batch loading through a target foreign-key field.
final class HasMany {
  /// Names the annotated target model and its foreign-key field.
  const HasMany(this.target, {required this.mappedBy});

  /// Annotated target model type.
  final Type target;

  /// Target foreign-key field pointing back to this model.
  final String mappedBy;
}

/// Enables optimistic locking for one non-null int field per model.
/// Inserts start at one; successful individual updates increment atomically.
/// Physical delete(model) checks the original version; forceDelete bypasses it.
/// Bulk updates and soft deletes/restores require individual models; upserts are rejected.
final class Version {
  /// Marks a database-managed positive integer version counter.
  const Version();
}

/// Declares an explicitly loaded nullable model through a local foreign-key field.
final class BelongsTo {
  /// Names the annotated target and the source Dart foreign-key field.
  const BelongsTo(this.target, {required this.foreignKey});

  /// Annotated target model type.
  final Type target;

  /// Local Dart field carrying @ForeignKey for the target.
  final String foreignKey;
}

/// Declares an explicitly loaded nullable model through a unique target foreign key.
final class OneToOne {
  /// Names the annotated target and its unique Dart foreign-key field.
  const OneToOne(this.target, {required this.mappedBy});

  /// Annotated target model type.
  final Type target;

  /// Target Dart foreign-key field pointing back to this source.
  final String mappedBy;
}
