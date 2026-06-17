import 'package:sqflite/sqflite.dart';

class SecurityStateDao {
  SecurityStateDao(this._db);
  final Database _db;

  Future<Map<String, int?>> readState() async {
    final rows = await _db.rawQuery(
      'SELECT last_wall_time_ms, last_monotonic_ms, last_run_at_ms FROM security_state WHERE id = 1 LIMIT 1',
    );
    if (rows.isEmpty) {
      return {
        'last_wall_time_ms': null,
        'last_monotonic_ms': null,
        'last_run_at_ms': null,
      };
    }
    final row = rows.first;
    return {
      'last_wall_time_ms': row['last_wall_time_ms'] as int?,
      'last_monotonic_ms': row['last_monotonic_ms'] as int?,
      'last_run_at_ms': row['last_run_at_ms'] as int?,
    };
  }

  Future<void> writeState({
    required int wallTimeMs,
    required int? monotonicMs,
    required int runAtMs,
  }) async {
    await _db.transaction((txn) async {
      final updated = await txn.rawUpdate(
        'UPDATE security_state SET last_wall_time_ms = ?, last_monotonic_ms = ?, last_run_at_ms = ? WHERE id = 1',
        [wallTimeMs, monotonicMs, runAtMs],
      );
      if (updated == 0) {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO security_state (id, last_wall_time_ms, last_monotonic_ms, last_run_at_ms) VALUES (1, ?, ?, ?)',
          [wallTimeMs, monotonicMs, runAtMs],
        );
      }
    });
  }
}
