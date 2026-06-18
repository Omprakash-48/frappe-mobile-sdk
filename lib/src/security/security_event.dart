import 'dart:convert';

import 'security_check.dart';

/// A single tamper-detection event persisted to the `security_events` table.
class SecurityEvent {
  const SecurityEvent({
    required this.id,
    required this.checkType,
    required this.detectedAtMs,
    this.wallTimeMs,
    this.serverAnchorMs,
    this.lastWallMs,
    this.monotonicMs,
    this.metadata,
  });

  final String id;
  final SecurityCheck checkType;

  /// [DateTime.now().millisecondsSinceEpoch] at time of detection.
  final int detectedAtMs;

  /// Device wall clock ms at detection (same as [detectedAtMs] in most cases).
  final int? wallTimeMs;

  /// MAX(cursor.modified) across all doctypes, when relevant.
  final int? serverAnchorMs;

  /// [security_state.last_wall_time_ms] at time of detection (for timeRollback).
  final int? lastWallMs;

  /// Native monotonic ms at detection (for monotonicRollback).
  final int? monotonicMs;

  /// JSON blob for check-specific extra data (e.g. last monotonic for monotonicRollback).
  final Map<String, dynamic>? metadata;

  factory SecurityEvent.fromMap(Map<String, Object?> row) {
    final raw = row['metadata'] as String?;
    return SecurityEvent(
      id: row['id'] as String,
      checkType: SecurityCheck.values.firstWhere(
        (c) => c.name == row['check_type'] as String,
      ),
      detectedAtMs: row['detected_at_ms'] as int,
      wallTimeMs: row['wall_time_ms'] as int?,
      serverAnchorMs: row['server_anchor_ms'] as int?,
      lastWallMs: row['last_wall_ms'] as int?,
      monotonicMs: row['monotonic_ms'] as int?,
      metadata: raw != null ? (jsonDecode(raw) as Map<String, dynamic>) : null,
    );
  }
}
