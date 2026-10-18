/// Isolation level used by `TikalDatabase.transaction`.
///
/// PostgreSQL and MySQL apply these levels to new transactions. SQLite accepts
/// them for portability but always uses its single serializable transaction mode.
enum TransactionIsolation {
  /// A statement only sees rows committed before it began. PostgreSQL default.
  readCommitted,

  /// Every statement in the transaction sees the same snapshot.
  repeatableRead,

  /// Fully serializable; may fail with a serialization error that the caller
  /// is expected to retry.
  serializable,
}
