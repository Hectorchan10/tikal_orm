import 'package:postgres/postgres.dart' as pg;

// Database
import '../query_result.dart';

/// Converts a driver row into a [TikalRow].
TikalRow mapDriverRow(pg.ResultRow row) {
  final names = <String>[
    for (final (index, column) in row.schema.columns.indexed)
      column.columnName ?? '[$index]',
  ];
  return TikalRow(columnNames: names, values: List<Object?>.of(row));
}

/// Converts a driver result into a [QueryResult].
QueryResult mapDriverResult(pg.Result result) => QueryResult(
  rows: <TikalRow>[for (final row in result) mapDriverRow(row)],
  affectedRows: result.affectedRows,
);
