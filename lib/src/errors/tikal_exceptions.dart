/// Base type for every error raised by TikalORM.
///
/// Catch [TikalException] to handle any library-specific failure, or catch a
/// concrete subtype to react to a specific problem.
abstract class TikalException implements Exception {
  const TikalException(this.message);

  /// Human readable description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a [PostgresConfig] is incomplete or invalid.
final class TikalConfigurationException extends TikalException {
  const TikalConfigurationException(super.message);
}

/// Thrown when TikalORM cannot open a connection or the connection is lost.
final class TikalConnectionException extends TikalException {
  const TikalConnectionException(super.message, {this.cause});

  /// The underlying error, when there is one.
  final Object? cause;

  @override
  String toString() => cause == null
      ? super.toString()
      : '${super.toString()} (caused by $cause)';
}

/// Thrown when a database handle is used after it has been closed.
final class TikalDatabaseClosedException extends TikalException {
  const TikalDatabaseClosedException(super.message);
}

/// Thrown when a query requests something the active engine cannot express.
///
/// This is a capability difference, not a defect: for example, SQLite's `LIKE`
/// operator is case-insensitive by default and cannot reproduce PostgreSQL's
/// case-sensitive `LIKE`, so a case-sensitive text match is rejected rather than
/// silently returning different rows on a different engine.
final class TikalUnsupportedException extends TikalException {
  const TikalUnsupportedException(super.message);
}

/// Thrown when a database server rejects a statement.
///
/// For PostgreSQL, the engine-specific diagnostics ([sqlState], [detail],
/// [hint], [constraint], ...) are preserved so callers can react to individual
/// error codes, for example `23505` (unique violation). Other engines fill the
/// fields they can provide.
final class TikalQueryException extends TikalException {
  TikalQueryException({
    required this.sql,
    this.parameters,
    this.serverMessage,
    this.sqlState,
    this.errorCode,
    this.detail,
    this.hint,
    this.table,
    this.column,
    this.constraint,
    this.cause,
  }) : super(_summary(sqlState: sqlState, serverMessage: serverMessage));

  /// The statement that failed.
  final String sql;

  /// The parameters that were bound to [sql], as passed by the caller.
  final Object? parameters;

  /// The message emitted by the server.
  final String? serverMessage;

  /// The 5-character PostgreSQL error code (`SQLSTATE`), when available.
  final String? sqlState;

  /// Numeric server diagnostic (e.g. MySQL 1062 for a duplicate key).
  final int? errorCode;

  /// Extra detail reported by the server.
  final String? detail;

  /// Server provided hint for fixing the problem.
  final String? hint;

  /// Table involved in the failure, when reported.
  final String? table;

  /// Column involved in the failure, when reported.
  final String? column;

  /// Constraint violated by the statement, when reported.
  final String? constraint;

  /// The underlying driver error.
  final Object? cause;

  static String _summary({String? sqlState, String? serverMessage}) {
    final text = serverMessage ?? 'The statement was rejected by the database.';
    return sqlState == null ? text : '$sqlState: $text';
  }

  @override
  String toString() {
    final buffer = StringBuffer('TikalQueryException: $message')
      ..write('\n  sql: $sql');
    if (detail != null) {
      buffer.write('\n  detail: $detail');
    }
    if (hint != null) {
      buffer.write('\n  hint: $hint');
    }
    if (table != null) {
      buffer.write('\n  table: $table');
    }
    if (column != null) {
      buffer.write('\n  column: $column');
    }
    if (constraint != null) {
      buffer.write('\n  constraint: $constraint');
    }
    return buffer.toString();
  }
}

/// Thrown when a Dart value cannot be bound as a SQL parameter.
final class TikalParameterException extends TikalException {
  const TikalParameterException(
    super.message, {
    this.position,
    this.value,
    this.cause,
  });

  /// Zero-based position of the offending parameter, when known.
  final int? position;

  /// The value that could not be bound.
  final Object? value;

  /// The underlying error, when there is one.
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('TikalParameterException: $message');
    if (position != null) {
      buffer.write('\n  position: $position');
    }
    if (value != null) {
      buffer.write('\n  valueType: ${value.runtimeType}');
    }
    if (cause != null) {
      buffer.write('\n  caused by: $cause');
    }
    return buffer.toString();
  }
}

/// Thrown when a column cannot be read from a [TikalRow].
final class TikalColumnException extends TikalException {
  const TikalColumnException(super.message, {this.column, this.available});

  /// Name of the column that could not be read.
  final String? column;

  /// Columns that were actually present in the row.
  final List<String>? available;

  @override
  String toString() {
    final buffer = StringBuffer('TikalColumnException: $message');
    if (available != null) {
      buffer.write('\n  available columns: ${available!.join(', ')}');
    }
    return buffer.toString();
  }
}

/// Thrown when a model is used incorrectly or has an unusable shape.
///
/// Examples: a table without a primary key where one is required, a composite
/// key used with a single-key API, a model with a missing mandatory field.
final class TikalModelException extends TikalException {
  const TikalModelException(super.message);
}

/// Thrown before a write when the model fails validation.
///
/// Validation combines the model's own rules (`TikalModel.validate`) with the
/// structural rules of its table definition (for example a `NOT NULL` column
/// without a default left unset).
final class TikalValidationException extends TikalException {
  TikalValidationException(List<String> errors)
    : errors = List<String>.unmodifiable(errors),
      super('Validation failed: ${errors.join('; ')}');

  /// One message per failed rule.
  final List<String> errors;

  @override
  String toString() {
    final buffer = StringBuffer(
      'TikalValidationException: ${errors.length} error(s)',
    );
    for (final error in errors) {
      buffer.write('\n  - $error');
    }
    return buffer.toString();
  }
}

/// Thrown when an operation expected a row that does not exist.
final class TikalEntityNotFoundException extends TikalException {
  TikalEntityNotFoundException({required this.table, this.primaryKey})
    : super(_message(table, primaryKey));

  /// Table that was searched.
  final String table;

  /// Primary key values used by the lookup.
  final Map<String, Object?>? primaryKey;

  static String _message(String table, Map<String, Object?>? primaryKey) {
    if (primaryKey == null || primaryKey.isEmpty) {
      return 'No row in "$table" matches the given key.';
    }
    return 'No row in "$table" matches key(${primaryKey.keys.join(', ')}).';
  }
}
