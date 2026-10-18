/// Marks a class for static seeder generation. Dependencies run in declared order,
/// before this class's optional run method. No registration happens on import.
/// Generation requires a public generative constructor callable without required
/// arguments and `Future<void> run()`, unless calls alone perform the work.
/// Duplicate names and dependency cycles throw FormatException during generation.
///
/// ```dart
/// @Seeder(calls: [RoleSeeder, UserSeeder])
/// class DatabaseSeeder {}
/// ```
final class Seeder {
  /// Marks a statically discovered seeder and its ordered dependencies.
  const Seeder({this.calls = const []});

  /// Seeder types executed sequentially before this class's optional run method.
  final List<Type> calls;
}
