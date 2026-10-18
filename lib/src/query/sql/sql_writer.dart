// SQL
import 'quoting.dart';
import '../../sql/sql_type.dart';
import '../../sql/sql_param.dart';

// Query
import '../dialects/dialect.dart';

// Database
import '../../database/query_executor.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

// SQL
import '../../sql/postgres/native_sql_value.dart';

/// SQL text and bound values. The dialect supplies placeholders and quoting;
/// bind never interpolates a value into SQL.
final class SqlWriter {
  /// Creates a statement writer using the selected engine syntax.
  SqlWriter({this.dialect = SqlDialect.postgres});

  /// SQL syntax, identifier quoting and placeholders used by this writer.
  final SqlDialect dialect;
  final StringBuffer _sql = StringBuffer();
  final List<Object?> _parameters = <Object?>[];

  /// The SQL text written so far.
  String get sql => _sql.toString();

  /// The values bound so far, in placeholder order.
  List<Object?> get parameters => List<Object?>.unmodifiable(_parameters);

  /// How many placeholders have been written.
  int get parameterCount => _parameters.length;

  /// Appends [text] verbatim.
  void write(String text) => _sql.write(text);

  /// Appends [name] as an identifier quoted for this writer's dialect.
  void writeIdentifier(String name) =>
      _sql.write(quotedIdentifier(name, dialect));

  /// Appends a placeholder for [value], inferring its type.
  ///
  /// Wrap [value] in a `SqlParam` when it needs an explicit type, for example an
  /// untyped `NULL`. PostgreSQL uses numbered `$1` placeholders; SQLite and
  /// MySQL use anonymous `?` placeholders bound by position.
  int bind(Object? value) {
    _parameters.add(value);
    _sql.write(dialect.strategy.placeholder(_parameters.length));
    return _parameters.length;
  }

  /// Appends a placeholder for [value] bound with [type].
  ///
  /// This is how column comparisons keep the column's own type (`uuid`,
  /// `numeric`, `timestamptz`, ...) instead of falling back to `text`.
  int bindTyped(SqlType type, Object? value) {
    if (value is NativeSqlValue) {
      if (!dialect.strategy.supportsPostgresSchema) {
        throw const TikalUnsupportedException(
          'PostgreSQL native bindings require PostgreSQL.',
        );
      }
      if (value.type == PostgresValueType.inet) {
        write('CAST(');
        final index = bind(SqlParam.of(type, value));
        write(' AS inet)');
        return index;
      }
    }
    return bind(SqlParam.of(type, value));
  }

  /// The SQL text and the bound values.
  SqlStatement build() =>
      SqlStatement(_sql.toString(), List<Object?>.unmodifiable(_parameters));

  @override
  String toString() => 'SqlWriter(${_sql.toString()}, $_parameters)';
}

/// A finished SQL statement: the text plus its positional parameters.
final class SqlStatement {
  /// Creates a statement from [sql] and [parameters].
  const SqlStatement(this.sql, this.parameters);

  /// The SQL text, with the dialect's placeholders (`$1`, ... or `?`).
  final String sql;

  /// Values aligned with the placeholders, ready to hand to a `QueryExecutor`.
  final List<Object?> parameters;

  @override
  String toString() => 'SqlStatement($sql, $parameters)';
}
