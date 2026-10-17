// Errors
import '../errors/tikal_exceptions.dart';

/// Generated callbacks reuse the application's configured Tikal connection.
final class SeederRegistry {
  SeederRegistry(Map<String, Future<void> Function()> seeders)
    : _seeders = Map.unmodifiable(seeders);

  final Map<String, Future<void> Function()> _seeders;

  /// Runs one seeder and its declared dependencies. Repeated calls run again;
  /// seeders control their own idempotency and transactions.
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
