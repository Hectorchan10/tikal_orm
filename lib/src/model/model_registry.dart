// Model
import 'table_definition.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// Explicit model metadata. Creating or importing a registry registers nothing.
final class ModelRegistry {
  ModelRegistry(Iterable<TableDefinition<Object>> definitions) {
    for (final definition in definitions) {
      if (_definitions.containsKey(definition.modelType)) {
        throw TikalConfigurationException(
          'Duplicate model: ${definition.modelType}.',
        );
      }
      _definitions[definition.modelType] = definition;
    }
  }

  final Map<Type, TableDefinition<Object>> _definitions = {};

  /// Resolves the original typed definition without erasing its model type.
  TableDefinition<T> definitionFor<T extends Object>() {
    final definition = _definitions[T];
    if (definition is TableDefinition<T>) return definition;
    throw TikalConfigurationException(
      'Model $T is not registered. Pass tikalModels to Tikal.configure.',
    );
  }
}
