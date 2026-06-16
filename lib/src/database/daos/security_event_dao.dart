import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../security/security_event.dart';
import '../../utils/sdk_log.dart';

class SecurityEventDao {
  SecurityEventDao(this._db);
  final Database _db;
  static const _uuid = Uuid();

  /// Upper bound on retained audit rows. The table is only written when a
  /// tamper check actually fires (a rare event), but a compromised device that
  /// trips checks repeatedly over months could otherwise grow it without
  /// bound. Newest rows are kept; older ones are trimmed after each insert.
  static const int maxRows = 1000;

  Future<void> insert(SecurityEvent event) async {
    await _db.insert('security_events', {
      'id': event.id.isEmpty ? _uuid.v4() : event.id,
      'check_type': event.checkType.name,
      'detected_at_ms': event.detectedAtMs,
      'wall_time_ms': event.wallTimeMs,
      'server_anchor_ms': event.serverAnchorMs,
      'last_wall_ms': event.lastWallMs,
      'monotonic_ms': event.monotonicMs,
      'metadata': event.metadata != null ? jsonEncode(event.metadata) : null,
    });
    // Keep only the most recently inserted [maxRows] events. Retention is
    // ordered by rowid (insertion order), NOT detected_at_ms: a clock-rollback
    // event is recorded with a rolled-back (smaller) timestamp, so ordering the
    // trim by timestamp could discard the very event we just logged. rowid is
    // immune to clock manipulation — exactly what this audit table guards.
    await _db.rawDelete(
      'DELETE FROM security_events WHERE id NOT IN '
      '(SELECT id FROM security_events ORDER BY rowid DESC LIMIT ?)',
      [maxRows],
    );
  }

  Future<List<SecurityEvent>> queryNewestFirst({int? limit}) async {
    // Bind LIMIT as a positional argument rather than interpolating it.
    final rows = limit != null
        ? await _db.rawQuery(
            'SELECT * FROM security_events ORDER BY detected_at_ms DESC LIMIT ?',
            [limit],
          )
        : await _db.rawQuery(
            'SELECT * FROM security_events ORDER BY detected_at_ms DESC',
          );
    // Audit data must stay readable even if a single row is corrupt — e.g. a
    // row written with a `check_type` from a newer or rolled-back build, or
    // malformed metadata JSON. Skip and log the offending row instead of
    // throwing out of the entire query.
    final events = <SecurityEvent>[];
    for (final row in rows) {
      try {
        events.add(SecurityEvent.fromMap(row));
      } catch (e) {
        sdkLog(
          'SecurityEventDao: skipping unreadable audit row '
          '(id=${row['id']}, check_type=${row['check_type']}) — $e',
        );
      }
    }
    return events;
  }
}
