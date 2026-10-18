import 'dart:io';

// Config
import 'server_config.dart';
import 'config_parsing.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// Immutable connection settings for a MySQL/MariaDB database.
final class MysqlConfig extends ServerConfig {
  /// Creates immutable MySQL/MariaDB settings and validates host, pool and collation.
  /// Sessions always use UTC; invalid settings throw TikalConfigurationException.
  MysqlConfig({
    super.host = 'localhost',
    super.port = 3306,
    required super.database,
    required super.username,
    super.password,
    this.secure = false,
    super.maxConnections = 5,
    this.collation = 'utf8mb4_general_ci',
    super.connectTimeout = const Duration(seconds: 15),
    super.queryTimeout,
  }) {
    if (!RegExp(r'^utf8mb4_[a-zA-Z0-9_]+$').hasMatch(collation)) {
      throw const TikalConfigurationException(
        'collation must be a utf8mb4 collation name.',
      );
    }
    if (queryTimeout != null && queryTimeout!.isNegative) {
      throw const TikalConfigurationException(
        'queryTimeout must not be negative.',
      );
    }
  }

  /// Builds a config from a `mysql://` or `mariadb://` URL.
  factory MysqlConfig.fromUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw const TikalConfigurationException(
        'Invalid MySQL URL. Expected mysql://user:password@host:port/database.',
      );
    }
    if (uri.scheme != 'mysql' && uri.scheme != 'mariadb') {
      throw TikalConfigurationException(
        'Unsupported URL scheme "${uri.scheme}". Expected mysql:// or mariadb://.',
      );
    }
    final credentials = uri.userInfo.split(':');
    final parameters = uri.queryParameters;
    _requireUtc([
      parameters['time_zone'],
      parameters['timezone'],
    ], fromUri: true);
    return MysqlConfig(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 3306,
      database: databaseFromUri(uri),
      username: credentials.isEmpty
          ? ''
          : Uri.decodeComponent(credentials.first),
      password: credentials.length < 2
          ? null
          : Uri.decodeComponent(credentials.sublist(1).join(':')),
      secure: parseBoolConfig(parameters['secure'], defaultValue: false),
      maxConnections: integerOption(parameters, 'max_connections', 5),
      collation: parameters['collation'] ?? 'utf8mb4_general_ci',
      connectTimeout: Duration(
        seconds: integerOption(parameters, 'connect_timeout', 15),
      ),
    );
  }

  /// Reads the configuration from environment variables.
  factory MysqlConfig.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    _requireUtc([env['MYSQL_TIME_ZONE'], env['MYSQL_TIMEZONE']]);
    for (final rawUrl in [env['DATABASE_URL'], env['MYSQL_URL']]) {
      if (rawUrl == null || rawUrl.isEmpty) continue;
      final uri = Uri.tryParse(rawUrl);
      if (uri != null && (uri.scheme == 'mysql' || uri.scheme == 'mariadb')) {
        return MysqlConfig.fromUri(rawUrl);
      }
    }
    final database = firstNonEmpty([
      env['MYSQL_DATABASE'],
      env['MYSQL_DB'],
      env['MYSQL_SCHEMA'],
    ]);
    final username = firstNonEmpty([env['MYSQL_USER'], env['MYSQL_USERNAME']]);
    final missing = <String>[
      if (database == null) 'MYSQL_DATABASE',
      if (username == null) 'MYSQL_USER',
    ];
    if (missing.isNotEmpty) {
      throw TikalConfigurationException(
        'Missing required environment variable(s): ${missing.join(', ')}. '
        'Set them, or provide a mysql:// DATABASE_URL, or build the config explicitly.',
      );
    }
    final port = firstNonEmpty([env['MYSQL_PORT']]);
    return MysqlConfig(
      host: firstNonEmpty([env['MYSQL_HOST']]) ?? 'localhost',
      port: port == null ? 3306 : parseIntConfig('MYSQL_PORT', port),
      database: database!,
      username: username!,
      password: firstNonEmpty([env['MYSQL_PASSWORD']]),
      secure: parseBoolConfig(env['MYSQL_SECURE'], defaultValue: false),
      collation: env['MYSQL_COLLATION'] ?? 'utf8mb4_general_ci',
    );
  }

  /// Whether MySQL transport encryption is enabled.
  final bool secure;

  /// Validated utf8mb4 collation used when opening MySQL sessions.
  final String collation;
  static const _unset = Object();

  /// Returns validated settings with the supplied replacements.
  /// Omitted optional values are preserved; passing null clears nullable settings.
  MysqlConfig copyWith({
    String? host,
    int? port,
    String? database,
    String? username,
    Object? password = _unset,
    bool? secure,
    int? maxConnections,
    String? collation,
    Duration? connectTimeout,
    Object? queryTimeout = _unset,
  }) => MysqlConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    database: database ?? this.database,
    username: username ?? this.username,
    password: password == _unset ? this.password : password as String?,
    secure: secure ?? this.secure,
    maxConnections: maxConnections ?? this.maxConnections,
    collation: collation ?? this.collation,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    queryTimeout: queryTimeout == _unset
        ? this.queryTimeout
        : queryTimeout as Duration?,
  );

  @override
  String describe() {
    return 'mysql://$username:***@$host:$port/$database';
  }

  // One field list keeps equality and hashing in sync.
  Record get _identity => (connectionIdentity, secure, collation);

  @override
  bool operator ==(Object other) =>
      other is MysqlConfig && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;

  @override
  String toString() => 'MysqlConfig(${describe()})';
}

void _requireUtc(Iterable<String?> values, {bool fromUri = false}) {
  for (final value in values.whereType<String>()) {
    // URL query parsing treats an unescaped '+' as a space.
    final normalized = fromUri ? value.replaceFirst(RegExp(r'^ '), '+') : value;
    if (normalized != '+00:00') {
      throw const TikalConfigurationException(
        'MySQL sessions require UTC (+00:00).',
      );
    }
  }
}
