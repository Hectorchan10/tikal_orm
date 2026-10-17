// Config
import 'database_config.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// SQLite file connection. Use `:memory:` for a private in-memory database.
/// SQLite has no host, credentials or connection pool.
final class SqliteConfig implements DatabaseConfig {
  SqliteConfig({required this.path}) {
    if (path.trim().isEmpty || path.contains('\u0000')) {
      throw const TikalConfigurationException(
        'SQLite path must be nonempty and contain no NUL.',
      );
    }
  }

  final String path;

  /// Per-statement timeouts are unsupported by the synchronous SQLite driver.
  @override
  Duration? get queryTimeout => null;

  @override
  String describe() => 'sqlite:$path';

  @override
  String toString() => 'SqliteConfig(${describe()})';
}
