/// Marks a class for static seeder generation. Dependencies run in declared order,
/// before this class's optional run method. No registration happens on import.
final class Seeder {
  const Seeder({this.calls = const []});
  final List<Type> calls;
}
