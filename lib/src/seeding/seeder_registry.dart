// Errors
import '../errors/tikal_exceptions.dart';

/// Generated callbacks reuse the application's configured Tikal connection.
final class SeederRegistry {
  /// Copies the statically generated name-to-callback mapping without executing seeders.
  SeederRegistry(Map<String, Future<void> Function()> seeders)
    : _seeders = Map.unmodifiable(seeders);

  final Map<String, Future<void> Function()> _seeders;

  /// Runs one seeder and its declared dependencies. Repeated calls run again;
  /// seeders control their own idempotency and transactions.
  /// Throws TikalConfigurationException for an unknown name. Callback failures
  /// propagate and prevent subsequent calls; the application owns connection setup
  /// and cleanup. The same registry works with PostgreSQL, SQLite and MySQL.
  Future<void> run({String className = 'DatabaseSeeder'}) {
    final seed = _seeders[className];
    if (seed == null) {
      throw TikalConfigurationException(
        'Unknown seeder "$className". Available: ${_seeders.keys.join(', ')}. '
        'Run tikal generate after adding seeders.',
      );
    }
    return seed();
  }
}
