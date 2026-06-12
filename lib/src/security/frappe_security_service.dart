import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:root_checker_plus/root_checker_plus.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import 'security_check.dart';
import 'security_event.dart';
import 'security_exception.dart';
import 'security_platform_channel.dart';

/// Injectable root/jailbreak checker — returns `true` if the device is rooted.
typedef RootChecker = Future<bool> Function();

/// Injectable location mock checker — returns `true` if GPS is mocked,
/// `false` if not, or `null` when location permission is unavailable.
typedef LocationChecker = Future<bool?> Function();

/// Injectable monotonic-clock getter — returns milliseconds since device boot,
/// or `null` when the platform channel is unavailable.
typedef MonotonicGetter = Future<int?> Function();

/// Runs device-integrity checks and throws [SecurityCannotBeAssuredException]
/// if any enabled check fires. All checks run before throwing so [failedChecks]
/// is always complete. Every detected breach is written to `security_events`.
class FrappeSecurityService {
  FrappeSecurityService({
    required AppDatabase database,
    this.enabled = false,
    this.checks = const {},
    this.restartGapMs = 600000,
    RootChecker? rootChecker,
    LocationChecker? locationChecker,
    MonotonicGetter? monotonicGetter,
  }) : _db = database,
       _rootChecker = rootChecker ?? _defaultRootCheck,
       _locationChecker = locationChecker ?? _defaultLocationCheck,
       _monotonicGetter =
           monotonicGetter ?? SecurityPlatformChannel.getMonotonicMillis;

  final AppDatabase _db;
  final bool enabled;
  final Set<SecurityCheck> checks;

  /// Minimum monotonic-clock milliseconds that must have elapsed since boot
  /// before a drop in the monotonic value is treated as a rollback rather
  /// than a fresh device restart. Default is 10 minutes (600 000 ms).
  final int restartGapMs;

  final RootChecker _rootChecker;
  final LocationChecker _locationChecker;
  final MonotonicGetter _monotonicGetter;

  static const _uuid = Uuid();

  static Future<bool> _defaultRootCheck() async {
    // isRootChecker() returns Future<bool?> — treat null as false.
    return (await RootCheckerPlus.isRootChecker()) == true;
  }

  static Future<bool?> _defaultLocationCheck() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.lowest,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return position.isMocked;
    } catch (_) {
      return null;
    }
  }

  /// Runs all enabled checks. Throws [SecurityCannotBeAssuredException] if any
  /// check fires, after writing every failure to the audit log. The state
  /// snapshot (`security_state`) is always updated at the end — even when
  /// checks failed — so the next run has a fresh reference point.
  Future<void> runChecks() async {
    if (!enabled || checks.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final failed = <SecurityCheck>{};

    final state = await _db.securityStateDao.readState();
    final lastWallMs = state['last_wall_time_ms'];
    final lastMonotonicMs = state['last_monotonic_ms'];
    final currentMonotonicMs = await _monotonicGetter();

    // 1. Root / jailbreak
    if (checks.contains(SecurityCheck.root)) {
      if (await _rootChecker()) {
        failed.add(SecurityCheck.root);
        await _db.securityEventDao.insert(SecurityEvent(
          id: _uuid.v4(),
          checkType: SecurityCheck.root,
          detectedAtMs: nowMs,
          wallTimeMs: nowMs,
        ));
      }
    }

    // 2. Mock GPS location
    if (checks.contains(SecurityCheck.mockLocation)) {
      final isMocked = await _locationChecker();
      if (isMocked == true) {
        failed.add(SecurityCheck.mockLocation);
        await _db.securityEventDao.insert(SecurityEvent(
          id: _uuid.v4(),
          checkType: SecurityCheck.mockLocation,
          detectedAtMs: nowMs,
          wallTimeMs: nowMs,
        ));
      }
    }

    // 3. Wall-clock rollback (cross-session): skip on first run (lastWallMs null)
    if (checks.contains(SecurityCheck.timeRollback) && lastWallMs != null) {
      if (nowMs < lastWallMs) {
        failed.add(SecurityCheck.timeRollback);
        await _db.securityEventDao.insert(SecurityEvent(
          id: _uuid.v4(),
          checkType: SecurityCheck.timeRollback,
          detectedAtMs: nowMs,
          wallTimeMs: nowMs,
          lastWallMs: lastWallMs,
        ));
      }
    }

    // 4. Monotonic clock rollback.
    // Skipped when:
    //   • the channel is absent (currentMonotonicMs == null)
    //   • currentMonotonicMs < restartGapMs (device just rebooted — a drop
    //     vs. the stored value is expected)
    //   • no prior monotonic state exists (lastMonotonicMs == null)
    if (checks.contains(SecurityCheck.monotonicRollback) &&
        currentMonotonicMs != null &&
        currentMonotonicMs >= restartGapMs &&
        lastMonotonicMs != null) {
      if (currentMonotonicMs < lastMonotonicMs) {
        failed.add(SecurityCheck.monotonicRollback);
        await _db.securityEventDao.insert(SecurityEvent(
          id: _uuid.v4(),
          checkType: SecurityCheck.monotonicRollback,
          detectedAtMs: nowMs,
          wallTimeMs: nowMs,
          monotonicMs: currentMonotonicMs,
          metadata: {'last_monotonic_ms': lastMonotonicMs},
        ));
      }
    }

    // 5. Server time anchor.
    // Skipped automatically when no cursor exists (never synced).
    if (checks.contains(SecurityCheck.serverTimeAnchor)) {
      final anchorMs = await _queryServerAnchorMs();
      if (anchorMs != null && nowMs < anchorMs) {
        failed.add(SecurityCheck.serverTimeAnchor);
        await _db.securityEventDao.insert(SecurityEvent(
          id: _uuid.v4(),
          checkType: SecurityCheck.serverTimeAnchor,
          detectedAtMs: nowMs,
          wallTimeMs: nowMs,
          serverAnchorMs: anchorMs,
        ));
      }
    }

    // Always update reference state, even when checks failed, so the next
    // call has a fresh wall-time and monotonic baseline.
    await _db.securityStateDao.writeState(
      wallTimeMs: nowMs,
      monotonicMs: currentMonotonicMs,
      runAtMs: nowMs,
    );

    if (failed.isNotEmpty) throw SecurityCannotBeAssuredException(failed);
  }

  /// Returns audit log events newest-first, optionally limited to [limit] rows.
  Future<List<SecurityEvent>> getAuditLog({int? limit}) =>
      _db.securityEventDao.queryNewestFirst(limit: limit);

  /// Reads `doctype_meta.last_ok_cursor` for all rows and returns the
  /// maximum `modified` timestamp as milliseconds-since-epoch, or `null`
  /// if no valid cursor exists.
  ///
  /// The `modified` field in Frappe cursors is stored as a UTC datetime
  /// string without a timezone suffix (e.g. `"2026-06-12 09:30:00"`).
  /// We append `'Z'` after converting the space separator to `'T'` so
  /// that `DateTime.parse` treats the value as UTC — matching the
  /// encoding used when cursors are written.
  Future<int?> _queryServerAnchorMs() async {
    final rows = await _db.rawDatabase.rawQuery(
      'SELECT last_ok_cursor FROM doctype_meta WHERE last_ok_cursor IS NOT NULL',
    );
    int? maxMs;
    for (final row in rows) {
      try {
        final cursor =
            jsonDecode(row['last_ok_cursor'] as String) as Map<String, dynamic>;
        final modified = cursor['modified'] as String?;
        if (modified == null || modified.isEmpty) continue;

        // Normalise to an unambiguous ISO-8601 UTC string:
        //   "2026-06-12 09:30:00" → "2026-06-12T09:30:00Z"
        // The trailing 'Z' is only appended when the original value has no
        // timezone marker, preventing double-appending on already-correct input.
        final iso = modified.replaceFirst(' ', 'T');
        final utcIso = (iso.endsWith('Z') || iso.contains('+')) ? iso : '${iso}Z';

        final dt = DateTime.tryParse(utcIso);
        if (dt == null) continue;
        final ms = dt.toUtc().millisecondsSinceEpoch;
        if (maxMs == null || ms > maxMs) maxMs = ms;
      } catch (_) {
        continue;
      }
    }
    return maxMs;
  }
}
