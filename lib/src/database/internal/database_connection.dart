// Database
import '../query_executor.dart';

/// Internal lifecycle shared by implemented database engines.
abstract interface class DatabaseConnection
    implements QueryExecutor, TransactionExecutor {
  /// Whether an initialized connection is currently available.
  bool get isOpen;

  /// Opens and validates the connection once; concurrent calls share initialization.
  /// Throws TikalConnectionException on failure or TikalDatabaseClosedException after close.
  Future<void> open();

  /// Closes the connection and releases its resources.
  /// An in-flight open is awaited; force requests immediate shutdown where supported.
  Future<void> close({bool force = false});

  /// Returns whether the initialized connection answers a health-check query.
  Future<bool> ping();

  /// Runs the callback on one borrowed connection.
  /// The session must not escape the callback; failures propagate to the caller.
  Future<T> session<T>(
    Future<T> Function(QueryExecutor) action, {
    Duration? timeout,
  });
}
