import 'package:meta/meta.dart';

// Errors
import '../errors/tikal_exceptions.dart';

/// SQL with anonymous placeholders and values in occurrence order.
final class RewrittenNamedQuery {
  const RewrittenNamedQuery(this.sql, this.parameters);
  final String sql;
  final List<Object?> parameters;
}

/// Shared named binder. Doubled quotes, literals and comments are copied
/// verbatim. MySQL additionally accepts backslash escapes and # comments.
/// MySQL sessions must keep NO_BACKSLASH_ESCAPES disabled.
@internal
RewrittenNamedQuery rewriteNamedParameters(
  String sql,
  Map<String, Object?> parameters, {
  bool mysql = false,
}) {
  final buffer = StringBuffer();
  final values = <Object?>[];
  var i = 0;
  while (i < sql.length) {
    final char = sql[i];
    if (sql.startsWith('@@', i)) {
      while (i < sql.length && sql[i] == '@') {
        buffer.write(sql[i++]);
      }
    } else if (char == "'" ||
        char == '"' ||
        char == '`' ||
        (!mysql && char == '[')) {
      final quote = char == '[' ? ']' : char;
      buffer.write(sql[i++]);
      while (i < sql.length) {
        final current = sql[i++];
        buffer.write(current);
        if (mysql && current == r'\' && i < sql.length) {
          buffer.write(sql[i++]);
        } else if (current == quote) {
          if (i >= sql.length || sql[i] != quote) break;
          buffer.write(sql[i++]);
        }
      }
    } else if ((sql.startsWith('--', i) &&
            (!mysql || i + 2 == sql.length || sql.codeUnitAt(i + 2) <= 32)) ||
        (mysql && char == '#')) {
      final end = sql.indexOf('\n', i);
      final stop = end < 0 ? sql.length : end + 1;
      buffer.write(sql.substring(i, stop));
      i = stop;
    } else if (sql.startsWith('/*', i)) {
      final end = sql.indexOf('*/', i + 2);
      final stop = end < 0 ? sql.length : end + 2;
      buffer.write(sql.substring(i, stop));
      i = stop;
    } else if (char == '@' &&
        i + 1 < sql.length &&
        _identStart.hasMatch(sql[i + 1])) {
      var end = i + 2;
      while (end < sql.length && _identPart.hasMatch(sql[end])) {
        end++;
      }
      final name = sql.substring(i + 1, end);
      final key = parameters.containsKey(name) ? name : '@$name';
      if (!parameters.containsKey(key)) {
        throw TikalParameterException(
          'Missing value for named parameter "@$name".',
        );
      }
      buffer.write('?');
      values.add(parameters[key]);
      i = end;
    } else {
      buffer.write(sql[i++]);
    }
  }
  return RewrittenNamedQuery(buffer.toString(), List.unmodifiable(values));
}

final _identStart = RegExp(r'[a-zA-Z_]');
final _identPart = RegExp(r'[a-zA-Z0-9_]');
