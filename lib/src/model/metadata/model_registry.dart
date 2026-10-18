// Model
import 'table_definition.dart';

// Schema
import '../../schema/schema.dart';

// Database
import '../../database/query_executor.dart';

// Errors
import '../../errors/tikal_exceptions.dart';

/// Explicit model metadata. Creating or importing a registry registers nothing.
final class ModelRegistry {
  /// Builds explicit model mappings.
  /// Throws TikalConfigurationException when two definitions register the same model type.
  ModelRegistry(Iterable<TableDefinition<Object>> definitions, {this.schema}) {
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

  /// Optional explicit creation metadata, including foreign keys and join tables.
  /// Generated registries supply it; configuration never executes its DDL.
  final SchemaSnapshot? schema;

  /// Original model definitions, used to retain runtime DDL overrides.
  Iterable<TableDefinition<Object>> get definitions => _definitions.values;

  /// Validates all model columns before configuring an engine.
  /// Throws [TikalUnsupportedException] for an unsupported binding type.
  void validateDialect(SqlDialect dialect) {
    for (final definition in _definitions.values) {
      definition.validateDialect(dialect);
    }
  }

  /// Resolves the original typed definition without erasing its model type.
  TableDefinition<T> definitionFor<T extends Object>() {
    final definition = _definitions[T];
    if (definition is TableDefinition<T>) return definition;
    throw TikalConfigurationException(
      'Model $T is not registered. Regenerate and configure through your application entry lib/tikal.dart.',
    );
  }
}
