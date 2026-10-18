/// Base type for every error raised by TikalORM.
///
/// Catch [TikalException] to handle any library-specific failure, or catch a
/// concrete subtype to react to a specific problem.
abstract class TikalException implements Exception {
  /// Creates an ORM error with a human-readable message.
  const TikalException(this.message);

  /// Human readable description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when database settings or model registry configuration are invalid.
final class TikalConfigurationException extends TikalException {
  /// Reports invalid database settings or a model registry configuration.
  const TikalConfigurationException(super.message);
}

/// Thrown when TikalORM cannot open a connection or the connection is lost.
final class TikalConnectionException extends TikalException {
  /// Reports a connection failure, optionally preserving the original cause.
  const TikalConnectionException(super.message, {this.cause});

  /// The underlying error, when there is one.
  final Object? cause;
}

/// Thrown when a database handle is used after it has been closed.
final class TikalDatabaseClosedException extends TikalException {
  /// Reports an operation attempted on a closed database or expired session.
  const TikalDatabaseClosedException(super.message);
}

/// Thrown when a query requests something the active engine cannot express.
///
/// This is a capability difference, not a defect: for example, SQLite's `LIKE`
/// operator is case-insensitive by default and cannot reproduce PostgreSQL's
/// case-sensitive `LIKE`, so a case-sensitive text match is rejected rather than
/// silently returning different rows on a different engine.
final class TikalUnsupportedException extends TikalException {
  /// Reports an operation the selected engine cannot represent safely.
  const TikalUnsupportedException(super.message);
}

/// Thrown when a database server rejects a statement.
///
/// For PostgreSQL, the engine-specific diagnostics ([sqlState], [detail],
/// [hint], [constraint], ...) are preserved so callers can react to individual
/// error codes, for example `23505` (unique violation). Other engines fill the
/// fields they can provide.
/// Remains directly constructible; base permits the typed constraint subtypes
/// while retaining the shared diagnostic contract.
base class TikalQueryException extends TikalException {
  /// Preserves server diagnostics and the bound statement that failed.
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

  /// Sensitive bound values, as passed by the caller. Never serialize this field
  /// or the entire exception into logs. Use [redactedDiagnostics] instead.
  final Object? parameters;

  /// Sensitive server message; inspect explicitly, never log automatically.
  final String? serverMessage;

  /// The 5-character PostgreSQL error code (`SQLSTATE`), when available.
  final String? sqlState;

  /// Numeric server diagnostic (e.g. MySQL 1062 for a duplicate key).
  final int? errorCode;

  /// Sensitive server detail, which can contain bound values.
  final String? detail;

  /// Sensitive server hint, for explicit inspection only.
  final String? hint;

  /// Table involved in the failure, when reported.
  final String? table;

  /// Column involved in the failure, when reported.
  final String? column;

  /// Constraint violated by the statement, when reported.
  final String? constraint;

  /// The underlying driver error.
  final Object? cause;

  /// Allowlisted diagnostics suitable for automatic logs: category and codes only.
  /// Full sql/parameters/serverMessage/detail/hint/cause and identifiers may contain
  /// sensitive data and require deliberate inspection outside automatic logging.
  Map<String, Object?> redactedDiagnostics() => Map.unmodifiable({
    'category': runtimeType.toString(),
    'sqlState': sqlState != null && RegExp(r'^[A-Z0-9]{5}$').hasMatch(sqlState!)
        ? sqlState
        : null,
    'errorCode': errorCode,
  });

  static String _summary({String? sqlState, String? serverMessage}) {
    final text = serverMessage ?? 'The statement was rejected by the database.';
    return sqlState == null ? text : '$sqlState: $text';
  }

  @override
  String toString() =>
      '$runtimeType: Query rejected'
      '${sqlState != null && RegExp(r"^[A-Z0-9]{5}$").hasMatch(sqlState!) ? ' [SQLSTATE $sqlState]' : ''}'
      '${errorCode == null ? '' : ' [errorCode $errorCode]'}';
}

/// A UNIQUE or primary-key constraint rejected the statement.
final class TikalUniqueViolation extends TikalQueryException {
  /// Preserves the original statement and all available engine diagnostics.
  TikalUniqueViolation({
    required super.sql,
    super.parameters,
    super.serverMessage,
    super.sqlState,
    super.errorCode,
    super.detail,
    super.hint,
    super.table,
    super.column,
    super.constraint,
    super.cause,
  });
}

/// A foreign-key constraint rejected the statement.
final class TikalForeignKeyViolation extends TikalQueryException {
  /// Preserves the original statement and all available engine diagnostics.
  TikalForeignKeyViolation({
    required super.sql,
    super.parameters,
    super.serverMessage,
    super.sqlState,
    super.errorCode,
    super.detail,
    super.hint,
    super.table,
    super.column,
    super.constraint,
    super.cause,
  });
}

/// A NOT NULL constraint or required value rejected the statement.
final class TikalNotNullViolation extends TikalQueryException {
  /// Preserves the original statement and all available engine diagnostics.
  TikalNotNullViolation({
    required super.sql,
    super.parameters,
    super.serverMessage,
    super.sqlState,
    super.errorCode,
    super.detail,
    super.hint,
    super.table,
    super.column,
    super.constraint,
    super.cause,
  });
}

/// Thrown when a Dart value cannot be bound as a SQL parameter.
final class TikalParameterException extends TikalException {
  /// Reports an invalid bound value, optionally identifying its position and cause.
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
      buffer.write('\n  causeType: ${cause.runtimeType}');
    }
    return buffer.toString();
  }
}

/// Thrown when a column cannot be read from a [TikalRow].
final class TikalColumnException extends TikalException {
  /// Reports a missing column, an out-of-range index or an incompatible decoded type.
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
  /// Reports invalid model metadata or an unsupported mapping operation.
  const TikalModelException(super.message);
}

/// Thrown before a write when the model fails validation.
///
/// Validation combines the model's own rules (`ModelLifecycle.validate`) with the
/// structural rules of its table definition (for example a `NOT NULL` column
/// without a default left unset).
final class TikalValidationException extends TikalException {
  /// Collects all model validation failures before executing a statement.
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
  /// Reports the table and optional primary key for a missing entity.
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

/// An optimistic write matched neither the key nor its expected version.
/// The row may have been deleted or modified; no extra existence query is made.
final class TikalConcurrencyException extends TikalException {
  /// Reports a missing or concurrently changed row without exposing key values.
  TikalConcurrencyException({
    required this.table,
    required this.expectedVersion,
  }) : super(
         'No row in "$table" matches the expected version $expectedVersion. '
         'It may have been deleted or concurrently modified.',
       );

  /// Table targeted by the optimistic write.
  final String table;

  /// Persisted counter supplied to the write predicate.
  final int expectedVersion;
}
