/// Isolation level used by `TikalDatabase.transaction`.
///
/// These map directly to the standard SQL transaction isolation levels.
enum TransactionIsolation {
  /// A statement only sees rows committed before it began. PostgreSQL default.
  readCommitted,

  /// Every statement in the transaction sees the same snapshot.
  repeatableRead,

  /// Fully serializable; may fail with a serialization error that the caller
  /// is expected to retry.
  serializable,
}
