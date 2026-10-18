import 'dart:async';

import 'package:meta/meta.dart';

// Database
import 'query_result.dart';
import 'query_executor.dart';
import 'transaction_isolation.dart';

/// Leading SQL operation; CTEs, comments and unrecognized statements are other.
enum QueryOperation {
  /// A leading SELECT statement.
  select,

  /// A leading INSERT statement.
  insert,

  /// A leading UPDATE statement.
  update,

  /// A leading DELETE statement.
  delete,

  /// An operation that cannot be reliably classified from its leading verb.
  other,
}

/// One completed QueryExecutor call, including the time waiting for its result.
/// Parameters, credentials, result rows and error details are never included.
/// SQL is the original template: literal secrets in raw SQL remain visible.
/// Connection setup and internal transaction control statements are not events.
final class QueryEvent {
  /// Creates a diagnostic event without retaining any bound values.
  const QueryEvent({
    required this.sql,
    required this.duration,
    required this.operation,
    required this.success,
  });

  /// Original SQL template, with placeholders instead of bound parameter values.
  final String sql;

  /// Elapsed execution time, excluding listener callbacks.
  final Duration duration;

  /// Leading verb when recognized; otherwise other.
  final QueryOperation operation;

  /// Whether execution returned successfully.
  final bool success;
}

/// Observes completed calls. Callback failures never change the query outcome.
/// Async callbacks are not awaited; their failures are also isolated.
typedef QueryListener = FutureOr<void> Function(QueryEvent event);

/// Connection-scoped observation shared with borrowed sessions and transactions.
@internal
final class QueryObservers {
  final _listeners = <QueryListener>[];
  static final _verb = RegExp(
    r'^\s*(SELECT|INSERT|UPDATE|DELETE)\b',
    caseSensitive: false,
  );

  void Function() add(QueryListener listener) {
    _listeners.add(listener);
    var removed = false;
    return () {
      if (removed) return;
      removed = true;
      _listeners.remove(listener);
    };
  }

  void clear() => _listeners.clear();

  QueryExecutor wrap(QueryExecutor executor, {bool active = false}) =>
      executor is TransactionExecutor
      ? _ObservedTransaction(executor, this, active)
      : _ObservedExecutor(executor, this);

  Future<T> run<T>(String sql, Future<T> Function() action) {
    if (_listeners.isEmpty) return action();
    return _record(sql, action);
  }

  Future<T> _record<T>(String sql, Future<T> Function() action) async {
    final timer = Stopwatch()..start();
    var success = false;
    try {
      final result = await action();
      success = true;
      return result;
    } finally {
      timer.stop();
      final verb = _verb.firstMatch(sql)?.group(1)?.toLowerCase();
      final operation =
          QueryOperation.values.where((v) => v.name == verb).firstOrNull ??
          QueryOperation.other;
      final event = QueryEvent(
        sql: sql,
        duration: timer.elapsed,
        operation: operation,
        success: success,
      );
      for (final listener in List<QueryListener>.of(_listeners)) {
        try {
          final result = listener(event);
          if (result is Future<void>) {
            unawaited(
              result.then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {
                  // Diagnostics cannot replace a successful result or original query error.
                },
              ),
            );
          }
        } catch (_) {
          // Diagnostics cannot replace a successful result or original query error.
        }
      }
    }
  }
}

class _ObservedExecutor implements QueryExecutor {
  const _ObservedExecutor(this.source, this.observers);
  final QueryExecutor source;
  final QueryObservers observers;
  @override
  SqlDialect get dialect => source.dialect;
  @override
  Future<QueryResult> query(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => observers.run(
    sql,
    () => source.query(sql, parameters: parameters, timeout: timeout),
  );
  @override
  Future<QueryResult> queryNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => observers.run(
    sql,
    () => source.queryNamed(sql, parameters: parameters, timeout: timeout),
  );
  @override
  Future<int> execute(
    String sql, {
    List<Object?> parameters = const [],
    Duration? timeout,
  }) => observers.run(
    sql,
    () => source.execute(sql, parameters: parameters, timeout: timeout),
  );
  @override
  Future<int> executeNamed(
    String sql, {
    Map<String, Object?> parameters = const {},
    Duration? timeout,
  }) => observers.run(
    sql,
    () => source.executeNamed(sql, parameters: parameters, timeout: timeout),
  );
}

final class _ObservedTransaction extends _ObservedExecutor
    implements TransactionExecutor, TransactionStateExecutor {
  const _ObservedTransaction(super.source, super.observers, this.active);
  final bool active;
  @override
  bool get isInTransaction =>
      active ||
      (source is TransactionStateExecutor &&
          (source as TransactionStateExecutor).isInTransaction);
  @override
  Future<T> transaction<T>(
    Future<T> Function(QueryExecutor) action, {
    TransactionIsolation? isolation,
    bool readOnly = false,
    Duration? timeout,
  }) => (source as TransactionExecutor).transaction(
    (tx) => action(observers.wrap(tx, active: true)),
    isolation: isolation,
    readOnly: readOnly,
    timeout: timeout,
  );
}
