import 'dart:convert';

import 'package:crypto/crypto.dart';

// Schema
import 'guards.dart';
import 'schema.dart';
import 'schema_inspector.dart' show SchemaInspector;

// Database
import '../tikal_database.dart';

// Errors
import '../errors/tikal_exceptions.dart';

// Executor
import '../executor/query_executor.dart';
import '../executor/transaction_isolation.dart';

/// A migration failed validation before executing its SQL.
final class TikalMigrationException extends TikalException {
  const TikalMigrationException(super.message);
}

/// A versioned, reviewable migration; its checksum covers SQL and snapshot.
final class Migration {
  Migration({
    required this.id,
    required Iterable<String> up,
    required Iterable<String> down,
    required this.snapshot,
    this.requiresReview = false,
    this.destructiveDown = false,
  }) : up = List.unmodifiable(up),
       down = List.unmodifiable(down) {
    if (!RegExp(r'^[0-9]{20}_[a-zA-Z0-9_]+$').hasMatch(id)) {
      throw TikalMigrationException('Invalid migration identifier: $id');
    }
  }
  final String id;
  final List<String> up, down;
  final SchemaSnapshot snapshot;
  final bool requiresReview, destructiveDown;
  Map<String, Object?> get _payload => {
    'version': 1,
    'id': id,
    'up': up,
    'down': down,
    'requiresReview': requiresReview,
    'destructiveDown': destructiveDown,
    'snapshot': snapshot.toJson(),
  };
  String get checksum =>
      sha256.convert(utf8.encode(jsonEncode(_payload))).toString();
  Map<String, Object?> toJson() => {..._payload, 'checksum': checksum};
  factory Migration.fromJson(Map<String, Object?> j) {
    if (j['version'] != 1) {
      throw TikalMigrationException('Unsupported migration format.');
    }
    final migration = Migration(
      id: j['id'] as String,
      up: (j['up'] as List).cast<String>(),
      down: (j['down'] as List).cast<String>(),
      snapshot: SchemaSnapshot.fromJson(
        (j['snapshot'] as Map).cast<String, Object?>(),
      ),
      requiresReview: j['requiresReview'] as bool,
      destructiveDown: j['destructiveDown'] as bool,
    );
    if (j['checksum'] != migration.checksum) {
      throw TikalMigrationException('Checksum mismatch for ${migration.id}.');
    }
    return migration;
  }
}

/// Runs explicitly requested PostgreSQL migrations, under a transaction lock.
/// No schema work runs during normal application startup.
final class MigrationRunner {
  MigrationRunner(this.executor) {
    requirePostgresSchema(executor);
    if (executor is! TransactionExecutor) {
      throw const TikalUnsupportedException(
        'Migrations require an executor with transaction support.',
      );
    }
  }
  final QueryExecutor executor;
  TransactionExecutor get _transactions => executor as TransactionExecutor;

  @Deprecated(
    'Use executor; migration execution only requires executor contracts.',
  )
  TikalDatabase get database => executor as TikalDatabase;
  static const _history = 'public._tikal_migrations';

  List<Migration> _ordered(Iterable<Migration> migrations) {
    final ordered = migrations.toList()..sort((a, b) => a.id.compareTo(b.id));
    if (ordered.map((m) => m.id).toSet().length != ordered.length) {
      throw TikalMigrationException('Duplicate migration identifiers.');
    }
    return ordered;
  }

  Future<void> _lock(QueryExecutor tx) async {
    await tx.query('SELECT pg_advisory_xact_lock(21462026)');
    await tx.execute(
      'CREATE TABLE IF NOT EXISTS $_history (id text PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP)',
    );
  }

  Future<Map<String, String>> _historyRows(QueryExecutor executor) async {
    final exists = await executor.query(
      "SELECT to_regclass('$_history') AS name",
    );
    if (exists.first['name'] == null) return {};
    final result = await executor.query(
      'SELECT id, checksum FROM $_history ORDER BY id',
    );
    return {
      for (final row in result.rows)
        row.asString('id')!: row.asString('checksum')!,
    };
  }

  void _validate(List<Migration> ordered, Map<String, String> applied) {
    final byId = {for (final m in ordered) m.id: m};
    for (final entry in applied.entries) {
      if (byId[entry.key]?.checksum != entry.value) {
        throw TikalMigrationException(
          'Applied migration ${entry.key} is missing or modified. Restore its original contents.',
        );
      }
    }
    final prefix = ordered.take(applied.length).map((m) => m.id).toSet();
    if (prefix.length != applied.length || !prefix.containsAll(applied.keys)) {
      throw TikalMigrationException(
        'Migration history is not an ordered prefix; a migration was added out of order.',
      );
    }
  }

  /// Read-only status, including checksum verification.
  Future<Map<String, bool>> status(Iterable<Migration> migrations) async {
    final ordered = _ordered(migrations);
    final applied = await _historyRows(executor);
    _validate(ordered, applied);
    return {for (final m in ordered) m.id: applied.containsKey(m.id)};
  }

  /// Read-only drift check against the latest applied, checksum-verified snapshot.
  Future<List<String>> check(Iterable<Migration> migrations) async {
    final ordered = _ordered(migrations);
    return _transactions.transaction(
      (tx) async {
        final applied = await _historyRows(tx);
        _validate(ordered, applied);
        return SchemaInspector(tx).check(
          applied.isEmpty
              ? SchemaSnapshot([])
              : ordered[applied.length - 1].snapshot,
        );
      },
      readOnly: true,
      isolation: TransactionIsolation.repeatableRead,
    );
  }

  /// Applies pending SQL and history atomically. Review flags require opt-in.
  Future<void> up(
    Iterable<Migration> migrations, {
    bool allowUnsafe = false,
  }) async {
    final ordered = _ordered(migrations);
    await _transactions.transaction((tx) async {
      await _lock(tx);
      final applied = await _historyRows(tx);
      _validate(ordered, applied);
      final pending = ordered.where((m) => !applied.containsKey(m.id)).toList();
      if (!allowUnsafe && pending.any((m) => m.requiresReview)) {
        throw TikalMigrationException(
          'Review potentially destructive changes and rerun with --allow-unsafe.',
        );
      }
      for (final migration in pending) {
        for (final sql in migration.up) {
          await tx.execute(sql);
        }
        await tx.execute(
          'INSERT INTO $_history (id, checksum) VALUES (\$1, \$2)',
          parameters: [migration.id, migration.checksum],
        );
      }
    });
  }

  /// Rolls back the latest migration only. Generated drops need explicit consent.
  Future<void> down(
    Iterable<Migration> migrations, {
    bool allowDestructive = false,
  }) async {
    final ordered = _ordered(migrations);
    await _transactions.transaction((tx) async {
      await _lock(tx);
      final applied = await _historyRows(tx);
      _validate(ordered, applied);
      if (applied.isEmpty) return;
      final migration = ordered[applied.length - 1];
      if (migration.down.isEmpty) {
        throw TikalMigrationException(
          'No safe inverse for ${migration.id}; write an explicit migration.',
        );
      }
      if (migration.destructiveDown && !allowDestructive) {
        throw TikalMigrationException(
          'Rollback drops data. Review it and use --allow-destructive to authorize.',
        );
      }
      for (final sql in migration.down) {
        await tx.execute(sql);
      }
      await tx.execute(
        'DELETE FROM $_history WHERE id = \$1',
        parameters: [migration.id],
      );
    });
  }
}
