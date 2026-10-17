import 'package:meta/meta.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// Returns the first non-null and non-empty string in [values], or `null`.
@internal
String? firstNonEmpty(List<String?> values) =>
    values.whereType<String>().where((value) => value.isNotEmpty).firstOrNull;

/// Extracts the decoded database name from the first path segment of [uri].
@internal
String databaseFromUri(Uri uri) {
  if (uri.pathSegments.isEmpty) return '';
  return Uri.decodeComponent(uri.pathSegments.first);
}

/// Parses an integer configuration value or throws [TikalConfigurationException].
@internal
int parseIntConfig(String name, String value) {
  final parsed = int.tryParse(value.trim());
  if (parsed == null) {
    throw TikalConfigurationException(
      '"$name" must be an integer, got "$value".',
    );
  }
  return parsed;
}

/// Parses a boolean configuration value or returns [defaultValue].
@internal
bool parseBoolConfig(String? value, {required bool defaultValue}) {
  if (value == null || value.isEmpty) return defaultValue;
  return switch (value.trim().toLowerCase()) {
    'true' || '1' || 'on' => true,
    'false' || '0' || 'off' => false,
    _ => throw const TikalConfigurationException(
      'Boolean configuration must be true/false, 1/0 or on/off.',
    ),
  };
}

/// Validates common network and pool connection settings.
@internal
void validateConfigCommon({
  required String host,
  required int port,
  required String database,
  required String username,
  required int maxConnections,
  required Duration connectTimeout,
}) {
  if (host.trim().isEmpty) {
    throw const TikalConfigurationException('host must not be empty.');
  }
  if (port < 1 || port > 65535) {
    throw TikalConfigurationException(
      'port must be between 1 and 65535, got $port.',
    );
  }
  if (database.trim().isEmpty) {
    throw const TikalConfigurationException('database must not be empty.');
  }
  if (username.trim().isEmpty) {
    throw const TikalConfigurationException('username must not be empty.');
  }
  if (maxConnections < 1) {
    throw TikalConfigurationException(
      'maxConnections must be at least 1, got $maxConnections.',
    );
  }
  if (connectTimeout.isNegative) {
    throw const TikalConfigurationException(
      'connectTimeout must not be negative.',
    );
  }
}

/// Reads an optional integer URL setting using the shared validation.
@internal
int integerOption(Map<String, String> options, String name, int fallback) {
  final value = options[name];
  return value == null ? fallback : parseIntConfig(name, value);
}
