// SQL
import 'sql/quoting.dart';
import 'sql/sql_writer.dart';
import '../sql/sql_type.dart';

// Query
import 'dialects/dialect.dart';
import 'expressions/order_by.dart';

// Database
import '../database/query_result.dart';

// Query
import 'expressions/sql_predicate.dart';

// Database
import '../database/query_executor.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Model
import '../model/metadata/model_column.dart';
import '../model/metadata/table_definition.dart';
import '../model/metadata/column_definition.dart';

/// How queries treat rows hidden by soft deletion.
enum TrashedScope {
  /// Exclude rows whose soft-delete column is set (the default).
  exclude,

  /// Return both live and soft-deleted rows.
  include,

  /// Return only soft-deleted rows.
  only,
}

/// A fluent, immutable `SELECT` builder for one model type.
///
/// A builder starts from a table definition and an executor and grows a
/// statement one clause at a time. Every method returns a **new** builder, so a
/// partially built query can be stored and reused as a base without later
/// branches affecting it:
///
/// ```dart
/// final active = users.where(User_.active.equals(true));
///
/// final byName = await active.orderBy(User_.name).get();
/// final newest = await active.orderBy(User_.createdAt, descending: true).get();
/// ```
///
/// The usual entry point is `Repository.where` / `Repository.query`, which seed
/// the builder from an existing repository:
///
/// ```dart
/// final users = await Tikal.model<User>().query()
///     .where(User_.active.equals(true))
///     .orderBy(User_.name)
///     .limit(20)
///     .get();
/// ```
///
/// Every value is bound as a parameter — nothing is interpolated into the SQL —
/// and predicates bind with their column's own SQL type, so `uuid`,
/// `numeric` and `timestamptz` comparisons behave exactly as the repository's
/// does. The builder emits the same SQL as `Repository.find`, so the two can be
/// mixed freely.
///
/// Soft-delete scopes are applied to every matching query and bulk deletion.
/// Bulk operations bypass model validation/hooks. Unsupported engine semantics
/// throw TikalUnsupportedException instead of silently changing results.
final class QueryBuilder<TModel extends Object> {
  /// Creates a builder that selects from [definition] through [executor].
  ///
  /// Prefer `Repository.query` / `Repository.where` when a repository already
  /// exists; this constructor is for code that only has a table definition.
  QueryBuilder({required this.executor, required this.definition, this.clock})
    : _predicate = null,
      _orderBy = <OrderBy<TModel>>[],
      _limit = null,
      _offset = null,
      _distinct = false,
      _trashed = TrashedScope.exclude,
      _timeout = null;

  /// Internal copy constructor; all clauses are already resolved by the caller.
  const QueryBuilder._(
    this.executor,
    this.definition,
    this.clock,
    this._predicate,
    this._orderBy,
    this._limit,
    this._offset,
    this._distinct,
    this._trashed,
    this._timeout,
  );

  /// The executor every statement runs through.
  ///
  /// This is a `TikalDatabase`, a transaction or a session, so a builder
  /// created inside `db.transaction` participates in that transaction.
  final QueryExecutor executor;

  /// Metadata for the table being queried.
  final TableDefinition<TModel> definition;

  /// Time source for bulk timestamps, inherited from Repository.clock.
  final DateTime Function()? clock;

  final SqlPredicate<TModel>? _predicate;
  final List<OrderBy<TModel>> _orderBy;
  final int? _limit;
  final int? _offset;
  final bool _distinct;
  final TrashedScope _trashed;
  final Duration? _timeout;

  /// Returns a copy of this builder with the given fields replaced.
  ///
  /// `null` means "keep the current value"; the builder never needs to clear a
  /// clause, so this keeps the call sites small.
  QueryBuilder<TModel> _copyWith({
    SqlPredicate<TModel>? predicate,
    List<OrderBy<TModel>>? orderBy,
    int? limit,
    int? offset,
    bool? distinct,
    TrashedScope? trashed,
    Duration? timeout,
  }) => QueryBuilder<TModel>._(
    executor,
    definition,
    clock,
    predicate ?? _predicate,
    orderBy ?? _orderBy,
    limit ?? _limit,
    offset ?? _offset,
    distinct ?? _distinct,
    trashed ?? _trashed,
    timeout ?? _timeout,
  );

  // ---------------------------------------------------------------------------
  // Fluent clauses
  // ---------------------------------------------------------------------------

  /// Adds `AND predicate` to the `WHERE` clause.
  ///
  /// Calling it more than once combines the predicates with `AND`:
  ///
  /// ```dart
  /// users.where(User_.active.equals(true)).where(User_.age.isNotNull());
  /// // WHERE "active" = $1 AND "age" IS NOT NULL
  /// ```
  QueryBuilder<TModel> where(SqlPredicate<TModel> predicate) => _copyWith(
    predicate: _predicate == null ? predicate : _predicate.and(predicate),
  );

  /// Adds `OR predicate` to the `WHERE` clause.
  ///
  /// ```dart
  /// users.where(User_.active.equals(true)).orWhere(User_.role.equals('admin'));
  /// // WHERE "active" = $1 OR "role" = $2
  /// ```
  QueryBuilder<TModel> orWhere(SqlPredicate<TModel> predicate) => _copyWith(
    predicate: _predicate == null ? predicate : _predicate.or(predicate),
  );

  /// Adds `ORDER BY column [ASC|DESC]` as the next sort term.
  ///
  /// Defaults to ascending. Call it repeatedly (or use [thenBy]) to sort by
  /// several columns; the terms are applied in the order given.
  QueryBuilder<TModel> orderBy(
    ModelColumn<TModel, Object?> column, {
    bool descending = false,
    NullsOrder? nulls,
  }) => orderByTerm(
    OrderBy<TModel>(column, descending: descending, nulls: nulls),
  );

  /// Alias for [orderBy], reading better after a first sort term.
  QueryBuilder<TModel> thenBy(
    ModelColumn<TModel, Object?> column, {
    bool descending = false,
    NullsOrder? nulls,
  }) => orderBy(column, descending: descending, nulls: nulls);

  /// Adds a pre-built [OrderBy] term.
  ///
  /// Useful when the sort is decided at runtime, for example from a query
  /// parameter, and the `OrderBy` values are collected beforehand.
  QueryBuilder<TModel> orderByTerm(OrderBy<TModel> term) =>
      _copyWith(orderBy: <OrderBy<TModel>>[..._orderBy, term]);

  /// Adds `LIMIT count`.
  QueryBuilder<TModel> limit(int count) => _copyWith(limit: count);

  /// Adds `OFFSET count`.
  QueryBuilder<TModel> offset(int count) => _copyWith(offset: count);

  /// Selects distinct rows (`SELECT DISTINCT ...`).
  QueryBuilder<TModel> distinct() => _copyWith(distinct: true);

  /// Sets the statement timeout for the queries this builder runs.
  QueryBuilder<TModel> timeout(Duration value) => _copyWith(timeout: value);

  /// Includes soft-deleted rows alongside live ones.
  ///
  /// No-op when the table does not support soft deletes.
  QueryBuilder<TModel> withTrashed() =>
      _copyWith(trashed: TrashedScope.include);

  /// Restricts the query to soft-deleted rows only.
  QueryBuilder<TModel> onlyTrashed() => _copyWith(trashed: TrashedScope.only);

  // ---------------------------------------------------------------------------
  // Terminals
  // ---------------------------------------------------------------------------

  /// The `SELECT` statement this builder would run.
  ///
  /// Handy for logging, tests and `EXPLAIN`; it does not touch the database.
  SqlStatement toSql() => _selectWriter().build();

  SqlWriter _selectWriter() {
    final dialect = executor.dialect;
    final writer = _statementWriter(
      'SELECT ${_distinct ? 'DISTINCT ' : ''}${definition.quotedColumnsFor(dialect)} FROM',
    );
    _writeWhere(writer);
    _writeOrderBy(writer);
    if (_limit != null) {
      writer.write(' LIMIT ');
      writer.bindTyped(SqlType.bigInteger, _limit);
    }
    if (_offset != null) {
      if (_limit == null) writer.write(dialect.strategy.offsetOnlyPrefix);
      writer.write(' OFFSET ');
      writer.bindTyped(SqlType.bigInteger, _offset);
    }
    return writer;
  }

  /// Runs the query and maps every row into a model.
  Future<List<TModel>> get() async {
    final result = await _executeSelect();
    return result.rows.map(definition.fromRow).toList(growable: false);
  }

  /// The first matching row, or `null` when there is none.
  ///
  /// Adds `LIMIT 1`; any `ORDER BY` decides which row is first.
  Future<TModel?> first() async {
    final result = await _copyWith(limit: 1)._executeSelect();
    final row = result.firstOrNull;
    return row == null ? null : definition.fromRow(row);
  }

  /// The first matching row, throwing [TikalEntityNotFoundException] when there
  /// is none.
  Future<TModel> firstOrFail() async =>
      await first() ??
      (throw TikalEntityNotFoundException(table: definition.name));

  /// The number of matching rows (`SELECT count(*) ...`).
  Future<int> count() async {
    final writer = _statementWriter(
      'SELECT count(*) AS ${quotedIdentifier('total', executor.dialect)} FROM',
    );
    _writeWhere(writer);

    final result = await _run(writer);
    return result.single.asInt('total') ?? 0;
  }

  /// Fetches one page and its total, ignoring existing limit and offset.
  /// Use a stable order (including a unique key). Count and records are separate
  /// statements; use a repeatable-read transaction when consistency is required.
  /// DISTINCT pagination is unsupported because count() counts matching rows.
  /// Throws [ArgumentError] for nonpositive page/perPage and [StateError] for DISTINCT.
  /// Ordering must include a unique key; concurrent writes can change counts unless
  /// the caller uses a repeatable-read transaction on PostgreSQL/MySQL.
  Future<Page<TModel>> paginate({int page = 1, int perPage = 20}) async {
    if (page < 1) throw ArgumentError.value(page, 'page', 'Must be positive.');
    if (perPage < 1) {
      throw ArgumentError.value(perPage, 'perPage', 'Must be positive.');
    }
    if (_distinct) throw StateError('DISTINCT pagination is not supported.');
    final total = await count();
    final records = await limit(perPage).offset((page - 1) * perPage).get();
    return Page(records: records, total: total, page: page, perPage: perPage);
  }

  /// Whether at least one row matches.
  Future<bool> exists() async {
    final dialect = executor.dialect;
    final writer = _statementWriter('SELECT EXISTS(SELECT 1 FROM');
    _writeWhere(writer);
    writer.write(') AS ${quotedIdentifier('present', dialect)}');

    final result = await _run(writer);
    // PostgreSQL returns a boolean; SQLite and MySQL return 0 / 1.
    final value = result.single['present'];
    return value == true || value == 1;
  }

  /// The sum of [column] over the matching rows, or `null` when there are none.
  Future<num?> sum(ModelColumn<TModel, Object?> column) =>
      _aggregate('sum', column);

  /// The smallest value of [column], or `null` when there are no rows.
  Future<num?> min(ModelColumn<TModel, Object?> column) =>
      _aggregate('min', column);

  /// The largest value of [column], or `null` when there are no rows.
  Future<num?> max(ModelColumn<TModel, Object?> column) =>
      _aggregate('max', column);

  /// The average of [column], or `null` when there are no rows.
  Future<num?> avg(ModelColumn<TModel, Object?> column) =>
      _aggregate('avg', column);

  SqlWriter _statementWriter(String verb) {
    final dialect = executor.dialect;
    return SqlWriter(dialect: dialect)
      ..write(verb)
      ..write(' ')
      ..write(definition.qualifiedNameFor(dialect));
  }

  /// Deletes every matching row and returns how many were removed.
  /// Throws [TikalUnsupportedException] for soft deletion of versioned models.
  ///
  /// When the table supports soft deletes, matching rows are marked with the
  /// current time instead of being removed; use [forceDelete] to remove them
  /// for good. Unlike `Repository.delete`, this bypasses model validation and
  /// operates on whatever the `WHERE` clause matches; with no predicate it
  /// affects the whole table (still excluding rows already soft-deleted, unless
  /// [withTrashed] was called). Use it for deliberate bulk operation.
  /// Throws [TikalUnsupportedException] when ORDER BY, LIMIT, OFFSET or DISTINCT is set.
  Future<int> delete() {
    _validateWriteClauses();
    final deleted = definition.deletedAtColumn;
    if (deleted == null) return forceDelete();
    final stamp = (clock ?? DateTime.now)().toUtc();
    return _updateValues({deleted: stamp, ?definition.updatedAtColumn: stamp});
  }

  /// Permanently removes every matching row with a real `DELETE`.
  ///
  /// The soft-delete filter still applies, so call [withTrashed] or
  /// [onlyTrashed] to reach rows that `delete` would otherwise just mark.
  /// Throws [TikalUnsupportedException] when ORDER BY, LIMIT, OFFSET or DISTINCT is set.
  Future<int> forceDelete() {
    _validateWriteClauses();
    final writer = _statementWriter('DELETE FROM');
    _writeWhere(writer);
    return _execute(writer);
  }

  /// Clears the soft-delete column of every matching row.
  /// Throws [TikalUnsupportedException] for versioned models.
  ///
  /// Unlike the other terminals this ignores the soft-delete scope and applies
  /// only the user predicate, so `where(...).restore()` restores the matching
  /// rows whether or not they are currently trashed. With no predicate it
  /// restores the whole table. Throws [TikalModelException] when the table does
  /// not support soft deletes.
  /// Throws [TikalUnsupportedException] when ORDER BY, LIMIT, OFFSET or DISTINCT is set.
  Future<int> restore() {
    _validateWriteClauses();
    _rejectVersionedBulk();
    final deleted = definition.deletedAtColumn;
    if (deleted == null) {
      throw TikalModelException(
        'Table "${definition.name}" does not support soft deletes.',
      );
    }
    final writer = _statementWriter('UPDATE')
      ..write(' SET ')
      ..writeIdentifier(deleted.name)
      ..write(' = NULL');
    final predicate = _predicate;
    if (predicate != null) {
      writer.write(' WHERE ');
      predicate.writeTo(writer);
    }
    return _execute(writer);
  }

  /// Updates every matching row, returning how many were affected.
  /// Throws [TikalUnsupportedException] for versioned models.
  ///
  /// [values] contains typed column assignments; values bind with the column's
  /// SQL type. Missing updated-at values use the repository clock. Like [delete],
  /// this bypasses model validation and applies to whatever the `WHERE` clause matches, so build the predicate carefully.
  ///
  /// ```dart
  /// await QueryBuilder<User>(executor: db, definition: User_.table)
  ///     .where(User_.active.equals(false))
  ///     .update([User_.bio.assign('archived')]);
  /// ```
  /// Throws [TikalUnsupportedException] when ORDER BY, LIMIT, OFFSET or DISTINCT is set.
  /// Throws [ArgumentError] before SQL if a SQL column name is assigned twice.
  Future<int> update(Iterable<ColumnAssignment<TModel>> values) {
    final names = <String>{};
    final assignments = <ColumnDefinition, Object?>{};
    for (final assignment in values) {
      if (!names.add(assignment.column.name)) {
        throw ArgumentError(
          'Duplicate assignment for table "${definition.name}", column "${assignment.column.name}".',
        );
      }
      assignments[assignment.column] = assignment.value;
    }
    return _updateValues(assignments);
  }

  Future<int> _updateValues(Map<ColumnDefinition, Object?> values) {
    _validateWriteClauses();
    _rejectVersionedBulk();
    if (values.isEmpty) {
      throw ArgumentError.value(
        values,
        'values',
        'An UPDATE needs at least one column to set.',
      );
    }
    final writer = _statementWriter('UPDATE')..write(' SET ');
    var index = 0;
    final updatedAt = definition.updatedAtColumn;
    final assignments = <ColumnDefinition, Object?>{
      ...values,
      if (updatedAt != null &&
          !values.keys.any((column) => column.name == updatedAt.name))
        updatedAt: (clock ?? DateTime.now)(),
    };
    for (final entry in assignments.entries) {
      if (index++ > 0) writer.write(', ');
      writer.writeIdentifier(entry.key.name);
      writer.write(' = ');
      writer.bindTyped(
        entry.key.sqlType,
        definition.encodeWriteValue(entry.key, entry.value),
      );
    }
    _writeWhere(writer);

    return _execute(writer);
  }

  void _rejectVersionedBulk() {
    if (definition.versionColumn != null) {
      throw const TikalUnsupportedException(
        'Versioned models require individual updates, soft deletes and restores.',
      );
    }
  }

  void _validateWriteClauses() {
    if (_orderBy.isNotEmpty || _limit != null || _offset != null || _distinct) {
      throw const TikalUnsupportedException(
        'Bulk writes do not support ORDER BY, LIMIT, OFFSET or DISTINCT.',
      );
    }
  }

  Future<int> _execute(SqlWriter writer) => executor.execute(
    writer.sql,
    parameters: writer.parameters,
    timeout: _timeout,
  );

  Future<QueryResult> _executeSelect() => _run(_selectWriter());

  Future<QueryResult> _run(SqlWriter writer) => executor.query(
    writer.sql,
    parameters: writer.parameters,
    timeout: _timeout,
  );

  Future<num?> _aggregate(String function, ColumnDefinition column) async {
    final dialect = executor.dialect;
    final writer = _statementWriter(
      'SELECT $function(${quotedIdentifier(column.name, dialect)}) AS ${quotedIdentifier('value', dialect)} FROM',
    );
    _writeWhere(writer);

    final result = await _run(writer);
    return result.single.asNum('value');
  }

  void _writeWhere(SqlWriter writer) {
    final softFilter = _softDeleteFilter();
    final predicate = _predicate;
    if (softFilter == null && predicate == null) return;
    writer.write(' WHERE ');
    if (softFilter != null) {
      softFilter.writeTo(writer);
      if (predicate != null) writer.write(' AND ');
    }
    predicate?.writeTo(writer);
  }

  SqlPredicate<TModel>? _softDeleteFilter() => switch (_trashed) {
    TrashedScope.exclude => definition.deletedFilter(isNull: true),
    TrashedScope.only => definition.deletedFilter(isNull: false),
    TrashedScope.include => null,
  };

  void _writeOrderBy(SqlWriter writer) {
    if (_orderBy.isEmpty) return;
    writer.write(' ORDER BY ');
    for (final (index, term) in _orderBy.indexed) {
      if (index > 0) writer.write(', ');
      term.writeTo(writer);
    }
  }

  @override
  String toString() => 'QueryBuilder(${definition.qualifiedName})';
}

/// Immutable records and metadata returned by QueryBuilder.paginate.
final class Page<T> {
  /// Creates immutable page records and their count/offset metadata.
  /// Supply positive page/perPage values; use paginate for validated metadata.
  Page({
    required List<T> records,
    required this.total,
    required this.page,
    required this.perPage,
  }) : records = List.unmodifiable(records);

  /// Immutable records returned for this page.
  final List<T> records;

  /// Total number of matching rows, ignoring the page limit and offset.
  final int total;

  /// One-based page number.
  final int page;

  /// Maximum number of records requested per page.
  final int perPage;

  /// Number of pages needed to contain the reported total.
  /// Throws [UnsupportedError] if this page was constructed with zero perPage.
  int get totalPages => (total + perPage - 1) ~/ perPage;

  /// Whether the reported total includes a page after this one.
  bool get hasNextPage => page < totalPages;

  /// Whether this page number is greater than one.
  bool get hasPreviousPage => page > 1;
}
