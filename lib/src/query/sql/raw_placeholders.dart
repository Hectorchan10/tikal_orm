import 'package:meta/meta.dart';

// Database
import '../../database/query_executor.dart';

/// Splits only executable placeholders, preserving SQL lexical contexts.
/// Outside quoted contexts, ?? escapes a literal question mark; PostgreSQL ?|
/// and ?& operators are literal. A lone PostgreSQL ? operator must use ??.
@internal
List<String> splitSqlPlaceholders(String sql, SqlDialect dialect) {
  final parts = <String>[];
  final text = StringBuffer();
  final mysql = dialect == SqlDialect.mysql;
  final postgres = dialect == SqlDialect.postgres;
  var i = 0;
  while (i < sql.length) {
    final char = sql[i];
    if (char == "'" ||
        char == '"' ||
        (!postgres && (char == '`' || char == '['))) {
      final end = char == '[' ? ']' : char;
      final escaped =
          mysql ||
          postgres &&
              char == "'" &&
              i > 0 &&
              (sql[i - 1] == 'E' || sql[i - 1] == 'e') &&
              (i == 1 ||
                  !RegExp(r'[a-zA-Z0-9_$\u0080-\uFFFF]').hasMatch(sql[i - 2]));
      text.write(sql[i++]);
      while (i < sql.length) {
        final current = sql[i++];
        text.write(current);
        if (escaped && current == r'\' && i < sql.length) {
          text.write(sql[i++]);
        } else if (current == end) {
          if (i == sql.length || sql[i] != end) break;
          text.write(sql[i++]);
        }
      }
    } else if ((sql.startsWith('--', i) &&
            (!mysql || i + 2 == sql.length || sql.codeUnitAt(i + 2) <= 32)) ||
        mysql && char == '#') {
      final end = sql.indexOf('\n', i);
      final stop = end < 0 ? sql.length : end + 1;
      text.write(sql.substring(i, stop));
      i = stop;
    } else if (sql.startsWith('/*', i)) {
      var depth = 1;
      text.write('/*');
      i += 2;
      while (i < sql.length && depth > 0) {
        if (postgres && sql.startsWith('/*', i)) {
          depth++;
          text.write('/*');
          i += 2;
        } else if (sql.startsWith('*/', i)) {
          depth--;
          text.write('*/');
          i += 2;
        } else {
          text.write(sql[i++]);
        }
      }
    } else if (postgres &&
        char == r'$' &&
        (i == 0 ||
            !RegExp(r'[a-zA-Z0-9_$\u0080-\uFFFF]').hasMatch(sql[i - 1]))) {
      final match = RegExp(
        r'\$(?:[a-zA-Z_\u0080-\uFFFF][a-zA-Z0-9_\u0080-\uFFFF]*)?\$',
      ).matchAsPrefix(sql, i);
      if (match == null) {
        text.write(sql[i++]);
        continue;
      }
      final tag = match[0]!;
      final end = sql.indexOf(tag, i + tag.length);
      final stop = end < 0 ? sql.length : end + tag.length;
      text.write(sql.substring(i, stop));
      i = stop;
    } else if (sql.startsWith('??', i)) {
      text.write('?');
      i += 2;
    } else if (postgres &&
        (sql.startsWith('?|', i) ||
            sql.startsWith('?&', i) ||
            sql.startsWith('@?', i))) {
      text.write(sql.substring(i, i + 2));
      i += 2;
    } else if (char == '?') {
      parts.add(text.toString());
      text.clear();
      i++;
    } else {
      text.write(sql[i++]);
    }
  }
  parts.add(text.toString());
  return parts;
}
