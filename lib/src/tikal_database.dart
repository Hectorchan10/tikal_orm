// Config
import 'config/mysql_config.dart';
import 'config/sqlite_config.dart';

// Executor
import 'executor/query_result.dart';

// Config
import 'config/database_config.dart';
import 'config/postgres_config.dart';

// Errors
import 'errors/tikal_exceptions.dart';

// Executor
import 'executor/query_executor.dart';
import 'executor/mysql_connection.dart';
import 'executor/sqlite_connection.dart';
import 'executor/database_connection.dart';
import 'executor/postgres_connection.dart';
import 'executor/transaction_isolation.dart';

/// Database handle selected directly from its engine-specific configuration.
/// Connections are reused until explicitly closed.
final class TikalDatabase implements DatabaseConnection, DialectExecutor {
  TikalDatabase(this.config)
    : _connection = switch (config) {
        PostgresConfig config => PostgresConnection(config),
        SqliteConfig config => SqliteConnection(config),
        MysqlConfig config => MysqlConnection(config),
        _ => throw const TikalConfigurationException(
          'Unsupported database configuration.',
        ),
      };

  /// Common settings. Narrow to PostgresConfig for PostgreSQL-specific fields.
  final DatabaseConfig config;
  final DatabaseConnection _connection;

  @override
  SqlDialect get dialect => dialectOf(_connection);
  @override
  bool get isOpen => _connection.isOpen;
  bool get isClosed => !isOpen;
  @override
  Future<void> open() => _connection.open();
  @override
  Future<bool> ping() => _connection.ping();
  @override
  Future<void> close({bool force = false}) => _connection.close(force: force);
  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => _connection.query(sql, parameters: parameters, timeout: timeout);
  @override
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => _connection.queryNamed(sql, parameters: parameters, timeout: timeout);
  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => _connection.execute(sql, parameters: parameters, timeout: timeout);
  @override
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => _connection.executeNamed(sql, parameters: parameters, timeout: timeout);
  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) => _connection.transaction(
    action,
    isolation: isolation,
    readOnly: readOnly,
    timeout: timeout,
  );
  @override
  Future<T> session<T>(
    Future<T> Function(QueryExecutor) action, {
    Duration? timeout,
  }) => _connection.session(action, timeout: timeout);
  @override
  String toString() => 'TikalDatabase(${config.describe()}, open: $isOpen)';
}
