/// Common lifecycle settings; connection fields belong to each engine.
abstract interface class DatabaseConfig {
  /// Default statement timeout, or null to use the engine default.
  Duration? get queryTimeout;

  /// Returns a connection description with credentials redacted.
  String describe();
}
