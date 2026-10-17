// Executor
import 'query_executor.dart';

/// Internal lifecycle shared by implemented database engines.
abstract interface class DatabaseConnection
    implements QueryExecutor, TransactionExecutor {
  bool get isOpen;
  Future<void> open();
  Future<void> close({bool force = false});
  Future<bool> ping();
  Future<T> session<T>(
    Future<T> Function(QueryExecutor) action, {
    Duration? timeout,
  });
}
