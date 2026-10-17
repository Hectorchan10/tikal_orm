import 'package:meta/meta.dart';

// Config
import 'config_parsing.dart';
import 'database_config.dart';

/// Common immutable network settings for the two pooled server engines.
@internal
abstract base class ServerConfig implements DatabaseConfig {
  ServerConfig({
    this.host = 'localhost',
    required this.port,
    required this.database,
    required this.username,
    this.password,
    this.maxConnections = 5,
    this.connectTimeout = const Duration(seconds: 15),
    this.queryTimeout,
  }) {
    validateConfigCommon(
      host: host,
      port: port,
      database: database,
      username: username,
      maxConnections: maxConnections,
      connectTimeout: connectTimeout,
    );
  }

  /// Hostname or IP address of the server.
  final String host;

  /// TCP port of the server.
  final int port;

  /// Name of the database.
  final String database;

  /// Role used to authenticate.
  final String username;

  /// Password for username; null permits driver-specific passwordless authentication.
  final String? password;

  /// Maximum number of pooled connections kept open.
  final int maxConnections;

  /// How long to wait for the initial connection.
  final Duration connectTimeout;

  /// Default timeout applied to every statement, when set.
  @override
  final Duration? queryTimeout;

  @internal
  Record get connectionIdentity => (
    host,
    port,
    database,
    username,
    password,
    maxConnections,
    connectTimeout,
    queryTimeout,
  );
}
