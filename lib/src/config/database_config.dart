/// Common lifecycle settings; connection fields belong to each engine.
abstract interface class DatabaseConfig {
  Duration? get queryTimeout;
  String describe();
}
