import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:root_checker_plus/root_checker_plus.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../utils/sdk_log.dart';
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
    this.timeRollbackToleranceMs = 10000,
    this.serverAnchorToleranceMs = 900000,
    RootChecker? rootChecker,
    LocationChecker? locationChecker,
    MonotonicGetter? monotonicGetter,
  }) : _db = database,
       _rootChecker = rootChecker ?? _defaultRootCheck,
       _locationChecker = locationChecker ?? _defaultLocationCheck,
       _monotonicGetter =
           monotonicGetter ?? SecurityPlatformChannel.getMonotonicMillis {
    // Footgun guard: a service that is enabled but has no checks silently
    // passes every run. That is a valid (if unusual) configuration, but it is
    // far more often a wiring mistake than an intention.
    if (enabled && checks.isEmpty) {
      sdkLog(
        'FrappeSecurityService: enabled=true but `checks` is empty — no '
        'integrity checks will run. Did you forget to pass `checks`?',
      );
    }
  }

  final AppDatabase _db;
  final bool enabled;
  final Set<SecurityCheck> checks;

  /// Minimum monotonic-clock milliseconds that must have elapsed since boot
  /// before a drop in the monotonic value is treated as a rollback rather
  /// than a fresh device restart. Default is 10 minutes (600 000 ms).
  final int restartGapMs;

  /// Grace window (ms) subtracted from the stored wall time before a backward
  /// jump is treated as a rollback. Absorbs benign backward NTP corrections and
  /// small clock fixes. Default is 10 seconds.
  final int timeRollbackToleranceMs;

  /// Grace window (ms) subtracted from the server-anchor time before the device
  /// clock being behind it is treated as a breach. Absorbs normal network
  /// latency and clock skew between device and server. Default is 15 minutes —
  /// rural deployments without reliable NTP commonly run 6–10 minutes of
  /// persistent skew, which a tighter window would flag as a false breach.
  /// Tighten via the constructor only where NTP is guaranteed.
  final int serverAnchorToleranceMs;

  final RootChecker _rootChecker;
  final LocationChecker _locationChecker;
  final MonotonicGetter _monotonicGetter;

  static const _uuid = Uuid();

  static Future<bool> _defaultRootCheck() async {
    try {
      // isRootChecker() returns Future<bool?> — treat null as false.
      return (await RootCheckerPlus.isRootChecker()) == true;
    } catch (e) {
      // Plugin unavailable (e.g. MissingPluginException) — fail open so a
      // platform-channel gap can never brick the app.
      sdkLog(
        'FrappeSecurityService: root check unavailable, treating as '
        'not-rooted — $e',
      );
      return false;
    }
  }

  static Future<bool?> _defaultLocationCheck() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // Keep `lowest`: `isMocked` is a device-side flag that needs no GPS
          // fix. Raising the accuracy tier adds 5–10s of cold-start latency on
          // every app launch for zero benefit here — never increase this.
          accuracy: LocationAccuracy.lowest,
          timeLimit: Duration(seconds: 10),
        ),
      );
      return position.isMocked;
    } catch (e) {
      // Permission denied / location unavailable — null means "unknown",
      // which the caller treats as a pass (fail open).
      sdkLog('FrappeSecurityService: location check unavailable — $e');
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
        await _db.securityEventDao.insert(
          SecurityEvent(
            id: _uuid.v4(),
            checkType: SecurityCheck.root,
            detectedAtMs: nowMs,
            wallTimeMs: nowMs,
          ),
        );
      }
    }

    // 2. Mock GPS location
    if (checks.contains(SecurityCheck.mockLocation)) {
      final isMocked = await _locationChecker();
      if (isMocked == true) {
        failed.add(SecurityCheck.mockLocation);
        await _db.securityEventDao.insert(
          SecurityEvent(
            id: _uuid.v4(),
            checkType: SecurityCheck.mockLocation,
            detectedAtMs: nowMs,
            wallTimeMs: nowMs,
          ),
        );
      }
    }

    // 3. Wall-clock rollback (cross-session): skip on first run (lastWallMs null)
    if (checks.contains(SecurityCheck.timeRollback) && lastWallMs != null) {
      // Tolerance absorbs benign backward NTP corrections / clock fixes.
      if (nowMs < lastWallMs - timeRollbackToleranceMs) {
        failed.add(SecurityCheck.timeRollback);
        await _db.securityEventDao.insert(
          SecurityEvent(
            id: _uuid.v4(),
            checkType: SecurityCheck.timeRollback,
            detectedAtMs: nowMs,
            wallTimeMs: nowMs,
            lastWallMs: lastWallMs,
          ),
        );
      }
    }

    // 4. Monotonic clock rollback.
    //
    // The monotonic clock counts milliseconds since boot and cannot be moved
    // backwards from device settings, so within a single boot session it only
    // ever increases. A *drop* (current < stored) therefore means one of:
    //   • the device rebooted (uptime reset to ~0, then grew again) — benign, or
    //   • the monotonic source itself was tampered with — a breach.
    //
    // We distinguish the two with the wall clock. After a genuine reboot the
    // real time elapsed since the last run (nowMs − lastWallMs) spans the time
    // the device was powered off, so it is *larger* than the current uptime.
    // When that holds we treat the drop as a reboot and pass — this is what
    // stops every post-reboot launch from being blocked. The rollback attack we
    // defend against drives the wall clock *backwards*, which makes the elapsed
    // delta small or negative, so it is never excused. (A same-session wall
    // rollback never reaches this branch — the monotonic value would not have
    // dropped — and is caught by check #3 above.)
    //
    // Skipped when the channel is absent, when uptime is still below
    // [restartGapMs] (a drop right after boot is expected and there is no stable
    // baseline yet), or when there is no prior monotonic state.
    if (checks.contains(SecurityCheck.monotonicRollback) &&
        currentMonotonicMs != null &&
        currentMonotonicMs >= restartGapMs &&
        lastMonotonicMs != null &&
        currentMonotonicMs < lastMonotonicMs) {
      final wallElapsedMs = lastWallMs != null ? nowMs - lastWallMs : null;
      final explainedByReboot =
          wallElapsedMs != null && wallElapsedMs > currentMonotonicMs;
      if (!explainedByReboot) {
        failed.add(SecurityCheck.monotonicRollback);
        await _db.securityEventDao.insert(
          SecurityEvent(
            id: _uuid.v4(),
            checkType: SecurityCheck.monotonicRollback,
            detectedAtMs: nowMs,
            wallTimeMs: nowMs,
            monotonicMs: currentMonotonicMs,
            metadata: {
              'last_monotonic_ms': lastMonotonicMs,
              'wall_elapsed_ms': wallElapsedMs,
            },
          ),
        );
      }
    }

    // 5. Server time anchor.
    // Skipped automatically when no cursor exists (never synced).
    if (checks.contains(SecurityCheck.serverTimeAnchor)) {
      final anchorMs = await _queryServerAnchorMs();
      // Tolerance absorbs network latency and modest device/server clock skew.
      // NOTE: the anchor is parsed as UTC (see [_queryServerAnchorMs]); this
      // assumes the server writes `modified` in UTC. If a deployment stores
      // local time, the anchor will be off by the UTC offset — surfaced below.
      //
      // Diagnostic: a delta beyond a day almost always means a misconfigured
      // (non-UTC) server clock rather than a genuine device rollback. Without
      // this log such a deployment would block every user with no visible
      // cause. See SECURITY.md → "Server time anchor (UTC assumption)".
      if (anchorMs != null && (anchorMs - nowMs).abs() > 86400000) {
        sdkLog(
          'FrappeSecurityService: server time anchor is '
          '${((anchorMs - nowMs) / 3600000).toStringAsFixed(1)}h from the '
          'device clock — check the server stores `modified` in UTC and that '
          'device/server clocks are roughly aligned.',
        );
      }
      if (anchorMs != null && nowMs < anchorMs - serverAnchorToleranceMs) {
        failed.add(SecurityCheck.serverTimeAnchor);
        await _db.securityEventDao.insert(
          SecurityEvent(
            id: _uuid.v4(),
            checkType: SecurityCheck.serverTimeAnchor,
            detectedAtMs: nowMs,
            wallTimeMs: nowMs,
            serverAnchorMs: anchorMs,
          ),
        );
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
        final utcIso = (iso.endsWith('Z') || iso.contains('+'))
            ? iso
            : '${iso}Z';

        final dt = DateTime.tryParse(utcIso);
        if (dt == null) continue;
        final ms = dt.toUtc().millisecondsSinceEpoch;
        if (maxMs == null || ms > maxMs) maxMs = ms;
      } catch (e) {
        // Malformed cursor JSON / unparseable timestamp — skip this row.
        sdkLog('FrappeSecurityService: skipping unparseable cursor — $e');
        continue;
      }
    }
    return maxMs;
  }
}
