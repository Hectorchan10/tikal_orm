import 'package:meta/meta.dart';

// Model
import '../model_state.dart';

@internal
final class RelationKey {
  RelationKey(Object? value) : value = snapshotValues({'key': value})['key'];
  final Object? value;
  @override
  bool operator ==(Object other) =>
      other is RelationKey && snapshotEquals(value, other.value);
  @override
  int get hashCode => _hash(value);
  static int _hash(Object? value) => switch (value) {
    Map() => Object.hashAllUnordered(
      value.entries.map((e) => Object.hash(e.key, _hash(e.value))),
    ),
    List() => Object.hashAll(value.map(_hash)),
    _ => value.hashCode,
  };
}
