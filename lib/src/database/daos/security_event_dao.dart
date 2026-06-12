import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../security/security_check.dart';
import '../../security/security_event.dart';

class SecurityEventDao {
  SecurityEventDao(this._db);
  final Database _db;
  static const _uuid = Uuid();

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
  }

  Future<List<SecurityEvent>> queryNewestFirst({int? limit}) async {
    final rows = await _db.rawQuery(
      'SELECT * FROM security_events ORDER BY detected_at_ms DESC'
      '${limit != null ? ' LIMIT $limit' : ''}',
    );
    return rows.map(SecurityEvent.fromMap).toList();
  }
}
