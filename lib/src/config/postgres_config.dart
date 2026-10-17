import 'dart:io';

// Config
import 'server_config.dart';
import 'config_parsing.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// Transport security used when talking to PostgreSQL.
///
/// The set of supported modes reflects the capabilities of the `postgres` 3.5.20
/// driver. Modes that require different validation semantics (e.g. `allow`/`prefer`
/// which may fall back to plain text, or `verify-ca` which validates the CA but
/// not the hostname) are rejected with a clear configuration error rather than
/// being treated as equivalent.
enum PostgresSslMode {
  /// No TLS. Fastest for local development, unsafe over untrusted networks.
  disable('disable'),

  /// Always use TLS, ignoring certificate validation errors.
  require('require'),

  /// Always use TLS and validate the server certificate including the hostname.
  verifyFull('verify-full');

  const PostgresSslMode(this.value);

  /// The value as written in a connection URL or in `POSTGRES_SSLMODE`.
  final String value;

  /// Parses [value] into a [PostgresSslMode].
  ///
  /// Throws a [TikalConfigurationException] for unknown values.
  static PostgresSslMode parse(String value) {
    final normalized = value.trim().toLowerCase().replaceAll('_', '-');
    return switch (normalized) {
      'disable' || 'disabled' || 'false' || 'off' => PostgresSslMode.disable,
      'require' || 'true' || 'on' => PostgresSslMode.require,
      'verify-full' || 'verifyfull' => PostgresSslMode.verifyFull,
      'allow' || 'prefer' => throw TikalConfigurationException(
        'SSL mode "$value" is not supported by the current postgres driver '
        '(postgres 3.5.20). Supported modes: disable, require, verify-full.',
      ),
      'verify-ca' || 'verifyca' => throw TikalConfigurationException(
        'SSL mode "$value" (CA-only validation) is not supported by the current '
        'postgres driver. Use verify-full or require instead.',
      ),
      _ => throw TikalConfigurationException(
        'Unknown SSL mode "$value". Supported modes: disable, require, verify-full.',
      ),
    };
  }
}

/// Immutable connection settings for a PostgreSQL database.
///
/// ```dart
/// final config = PostgresConfig(
///   host: 'localhost',
///   database: 'app',
///   username: 'app',
///   password: 'secret',
/// );
/// ```
///
/// Handles credentials in URLs, environment variables and safety checks, and
/// never prints the password in [toString].
final class PostgresConfig extends ServerConfig {
  PostgresConfig({
    super.host = 'localhost',
    super.port = 5432,
    required super.database,
    required super.username,
    super.password,
    this.sslMode = PostgresSslMode.disable,
    this.applicationName,
    super.maxConnections = 5,
    super.connectTimeout = const Duration(seconds: 15),
    super.queryTimeout,
  });

  /// Builds a config from a `postgres://` / `postgresql://` URL.
  ///
  /// Supported query parameters: `sslmode`, `application_name`,
  /// `connect_timeout` (seconds) and `max_connections`.
  factory PostgresConfig.fromUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw const TikalConfigurationException(
        'Invalid PostgreSQL URL. Expected postgres://user:password@host:port/database.',
      );
    }
    if (uri.scheme != 'postgres' && uri.scheme != 'postgresql') {
      throw TikalConfigurationException(
        'Unsupported URL scheme "${uri.scheme}". Expected postgres:// or postgresql://.',
      );
    }

    final credentials = uri.userInfo.split(':');
    final parameters = uri.queryParameters;

    return PostgresConfig(
      host: uri.host.isEmpty ? 'localhost' : uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: databaseFromUri(uri),
      username: credentials.isEmpty
          ? ''
          : Uri.decodeComponent(credentials.first),
      password: credentials.length < 2
          ? null
          : Uri.decodeComponent(credentials.sublist(1).join(':')),
      sslMode: PostgresSslMode.parse(parameters['sslmode'] ?? 'disable'),
      applicationName: parameters['application_name'],
      maxConnections: integerOption(parameters, 'max_connections', 5),
      connectTimeout: Duration(
        seconds: integerOption(parameters, 'connect_timeout', 15),
      ),
    );
  }

  /// Reads the configuration from environment variables.
  ///
  /// `DATABASE_URL` (or `POSTGRES_URL`) wins when present. Otherwise the
  /// `POSTGRES_*` variables are used, falling back to the `PG*` variables used
  /// by the PostgreSQL CLI tools:
  ///
  /// `POSTGRES_HOST`/`PGHOST`, `POSTGRES_PORT`/`PGPORT`, `POSTGRES_DB`/
  /// `PGDATABASE`, `POSTGRES_USER`/`PGUSER`, `POSTGRES_PASSWORD`/`PGPASSWORD`,
  /// `POSTGRES_SSLMODE` and `POSTGRES_APPLICATION_NAME`.
  ///
  /// When [environment] is omitted, the process environment is read. Passing a
  /// map makes the lookup testable and supports explicit application environment
  /// loaders. This package does not load `.env` files automatically.
  factory PostgresConfig.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;

    final rawUrl = firstNonEmpty([env['DATABASE_URL'], env['POSTGRES_URL']]);
    if (rawUrl != null) {
      final uri = Uri.tryParse(rawUrl);
      if (uri != null &&
          (uri.scheme == 'postgres' || uri.scheme == 'postgresql')) {
        return PostgresConfig.fromUri(rawUrl);
      }
    }

    final database = firstNonEmpty([
      env['POSTGRES_DB'],
      env['POSTGRES_DATABASE'],
      env['PGDATABASE'],
    ]);
    final username = firstNonEmpty([env['POSTGRES_USER'], env['PGUSER']]);
    final missing = <String>[
      if (database == null) 'POSTGRES_DB',
      if (username == null) 'POSTGRES_USER',
    ];
    if (missing.isNotEmpty) {
      throw TikalConfigurationException(
        'Missing required environment variable(s): ${missing.join(', ')}. '
        'Set them, or provide DATABASE_URL, or build the config explicitly.',
      );
    }

    final port = firstNonEmpty([env['POSTGRES_PORT'], env['PGPORT']]);

    return PostgresConfig(
      host: firstNonEmpty([env['POSTGRES_HOST'], env['PGHOST']]) ?? 'localhost',
      port: port == null ? 5432 : parseIntConfig('POSTGRES_PORT', port),
      database: database!,
      username: username!,
      password: firstNonEmpty([env['POSTGRES_PASSWORD'], env['PGPASSWORD']]),
      sslMode: PostgresSslMode.parse(env['POSTGRES_SSLMODE'] ?? 'disable'),
      applicationName: firstNonEmpty([env['POSTGRES_APPLICATION_NAME']]),
    );
  }

  /// Transport security mode.
  final PostgresSslMode sslMode;

  /// Value reported to PostgreSQL in `application_name`, useful in `pg_stat_activity`.
  final String? applicationName;

  static const _unset = Object();

  /// Returns a copy with the given fields replaced.
  ///
  /// To explicitly clear an optional value (set it to `null`), pass `null`
  /// directly. Existing values are preserved when the argument is omitted.
  PostgresConfig copyWith({
    String? host,
    int? port,
    String? database,
    String? username,
    Object? password = _unset,
    PostgresSslMode? sslMode,
    Object? applicationName = _unset,
    int? maxConnections,
    Duration? connectTimeout,
    Object? queryTimeout = _unset,
  }) => PostgresConfig(
    host: host ?? this.host,
    port: port ?? this.port,
    database: database ?? this.database,
    username: username ?? this.username,
    password: password == _unset ? this.password : password as String?,
    sslMode: sslMode ?? this.sslMode,
    applicationName: applicationName == _unset
        ? this.applicationName
        : applicationName as String?,
    maxConnections: maxConnections ?? this.maxConnections,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    queryTimeout: queryTimeout == _unset
        ? this.queryTimeout
        : queryTimeout as Duration?,
  );

  /// A safe, human readable description of the target. Never includes the password.
  @override
  String describe() {
    final name = applicationName == null ? '' : '/$applicationName';
    return 'postgres://$username:***@$host:$port/$database$name';
  }

  // One field list keeps equality and hashing in sync.
  Record get _identity => (connectionIdentity, sslMode, applicationName);

  @override
  bool operator ==(Object other) =>
      other is PostgresConfig && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;

  @override
  String toString() => 'PostgresConfig(${describe()})';
}
