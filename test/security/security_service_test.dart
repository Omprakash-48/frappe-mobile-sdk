import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/security/frappe_security_service.dart';
import 'package:frappe_mobile_sdk/src/security/security_check.dart';
import 'package:frappe_mobile_sdk/src/security/security_exception.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Minimal injectable service factory used throughout these tests.
FrappeSecurityService _svc(
  AppDatabase db, {
  bool enabled = true,
  Set<SecurityCheck> checks = const {SecurityCheck.root},
  Future<bool> Function()? rootChecker,
  Future<bool?> Function()? locationChecker,
  Future<int?> Function()? monotonicGetter,
  int restartGapMs = 600000,
}) => FrappeSecurityService(
  database: db,
  enabled: enabled,
  checks: checks,
  restartGapMs: restartGapMs,
  rootChecker: rootChecker ?? () async => false,
  locationChecker: locationChecker ?? () async => false,
  monotonicGetter: monotonicGetter ?? () async => 1000000,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() => AppDatabaseTestSeam.resetSingleton());

  // ── enabled=false ──────────────────────────────────────────────────────────

  group('disabled service', () {
    test(
      'enabled=false → returns immediately, no throw, checkers not called',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        var called = false;
        final svc = _svc(
          db,
          enabled: false,
          rootChecker: () async {
            called = true;
            return true;
          },
        );
        await expectLater(svc.runChecks(), completes);
        expect(called, isFalse);
        await db.close();
      },
    );

    test('empty checks set → returns immediately even when enabled', () async {
      final db = await AppDatabase.inMemoryDatabase();
      var called = false;
      final svc = _svc(
        db,
        checks: const {},
        rootChecker: () async {
          called = true;
          return true;
        },
      );
      await expectLater(svc.runChecks(), completes);
      expect(called, isFalse);
      await db.close();
    });
  });

  // ── root check ─────────────────────────────────────────────────────────────

  group('root check', () {
    test('isRooted=true → throws with root in failedChecks', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(db, rootChecker: () async => true);
      await expectLater(
        svc.runChecks(),
        throwsA(
          isA<SecurityCannotBeAssuredException>().having(
            (e) => e.failedChecks,
            'failedChecks',
            contains(SecurityCheck.root),
          ),
        ),
      );
      await db.close();
    });

    test('isRooted=false → no throw', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await expectLater(_svc(db).runChecks(), completes);
      await db.close();
    });

    test('failed root check is persisted to security_events', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(db, rootChecker: () async => true);
      try {
        await svc.runChecks();
      } on SecurityCannotBeAssuredException {
        // expected
      }
      final events = await db.securityEventDao.queryNewestFirst();
      expect(events, hasLength(1));
      expect(events.first.checkType, SecurityCheck.root);
      await db.close();
    });

    test('failed run still updates security_state', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(db, rootChecker: () async => true);
      try {
        await svc.runChecks();
      } on SecurityCannotBeAssuredException {
        // expected
      }
      final state = await db.securityStateDao.readState();
      expect(
        state['last_wall_time_ms'],
        isNotNull,
        reason: 'writeState must be called even when checks fail',
      );
      await db.close();
    });
  });

  // ── mock location ──────────────────────────────────────────────────────────

  group('mockLocation check', () {
    test('isMocked=true → throws', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(
        db,
        checks: {SecurityCheck.mockLocation},
        locationChecker: () async => true,
      );
      await expectLater(
        svc.runChecks(),
        throwsA(isA<SecurityCannotBeAssuredException>()),
      );
      await db.close();
    });

    test(
      'locationChecker returns null (permission denied) → no throw',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final svc = _svc(
          db,
          checks: {SecurityCheck.mockLocation},
          locationChecker: () async => null,
        );
        await expectLater(svc.runChecks(), completes);
        await db.close();
      },
    );
  });

  // ── time rollback ──────────────────────────────────────────────────────────

  group('timeRollback check', () {
    test('stored wall time is in the future → throws', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final farFuture =
          DateTime.now().millisecondsSinceEpoch + 100000000; // +27 hours
      await db.securityStateDao.writeState(
        wallTimeMs: farFuture,
        monotonicMs: null,
        runAtMs: farFuture,
      );
      final svc = _svc(db, checks: {SecurityCheck.timeRollback});
      await expectLater(
        svc.runChecks(),
        throwsA(
          isA<SecurityCannotBeAssuredException>().having(
            (e) => e.failedChecks,
            'failedChecks',
            contains(SecurityCheck.timeRollback),
          ),
        ),
      );
      await db.close();
    });

    test('no prior state → skipped (first run)', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(db, checks: {SecurityCheck.timeRollback});
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });

    test('stored wall time within tolerance window → no throw', () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Stored wall time only ~3s ahead — inside the default 10s tolerance,
      // so a benign backward NTP correction must NOT trigger a block.
      final slightlyAhead = DateTime.now().millisecondsSinceEpoch + 3000;
      await db.securityStateDao.writeState(
        wallTimeMs: slightlyAhead,
        monotonicMs: null,
        runAtMs: slightlyAhead,
      );
      final svc = _svc(db, checks: {SecurityCheck.timeRollback});
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });

    test(
      'after passing run, security_state.last_wall_time_ms is updated',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final svc = _svc(db, checks: {SecurityCheck.timeRollback});
        await svc.runChecks();
        final state = await db.securityStateDao.readState();
        expect(state['last_wall_time_ms'], isNotNull);
        await db.close();
      },
    );
  });

  // ── monotonic rollback ─────────────────────────────────────────────────────

  group('monotonicRollback check', () {
    test(
      'monotonic drop with no matching wall-time gap (tamper) → throws',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        // Last run was effectively "just now" in wall-clock terms, yet uptime
        // dropped from 5000s to 3000s. Only ~milliseconds of real time have
        // elapsed — far less than the 3000s of reported uptime — so a reboot
        // cannot explain the drop. That is the monotonic-tamper signature.
        final nowish = DateTime.now().millisecondsSinceEpoch;
        await db.securityStateDao.writeState(
          wallTimeMs: nowish,
          monotonicMs: 5000000,
          runAtMs: nowish,
        );
        final svc = _svc(
          db,
          checks: {SecurityCheck.monotonicRollback},
          monotonicGetter: () async => 3000000, // lower but > restartGap
        );
        await expectLater(
          svc.runChecks(),
          throwsA(isA<SecurityCannotBeAssuredException>()),
        );
        await db.close();
      },
    );

    test(
      'monotonic drop explained by a real reboot (large wall gap) → passes',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        // Regression for the post-reboot false positive: the device ran ~13.9h
        // (stored uptime 50_000_000 ms) and was last seen ~13h ago in wall
        // time. It then rebooted and the user reopens the app after 15 min of
        // new uptime (900_000 ms, still > restartGap). Real elapsed time (13h)
        // vastly exceeds the new uptime, so this is a reboot — NOT a rollback —
        // and must not block the user.
        final thirteenHoursMs = const Duration(hours: 13).inMilliseconds;
        final lastWall =
            DateTime.now().millisecondsSinceEpoch - thirteenHoursMs;
        await db.securityStateDao.writeState(
          wallTimeMs: lastWall,
          monotonicMs: 50000000,
          runAtMs: lastWall,
        );
        final svc = _svc(
          db,
          checks: {SecurityCheck.monotonicRollback},
          monotonicGetter: () async => 900000, // 15 min uptime, > restartGap
        );
        await expectLater(svc.runChecks(), completes);
        await db.close();
      },
    );

    test(
      'monotonic drop with backward wall jump (rollback after reboot) → throws',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        // Attacker reboots, then rolls the wall clock backwards. Uptime is a
        // small-but->restartGap value, and the stored wall time is now *ahead*
        // of "now" (clock went back), so the elapsed delta is negative and the
        // reboot escape does not apply — the rollback must be caught.
        final aheadWall =
            DateTime.now().millisecondsSinceEpoch +
            const Duration(hours: 1).inMilliseconds;
        await db.securityStateDao.writeState(
          wallTimeMs: aheadWall,
          monotonicMs: 5000000,
          runAtMs: aheadWall,
        );
        final svc = _svc(
          db,
          checks: {SecurityCheck.monotonicRollback},
          monotonicGetter: () async => 700000, // ~11.6 min uptime, > restartGap
        );
        await expectLater(
          svc.runChecks(),
          throwsA(isA<SecurityCannotBeAssuredException>()),
        );
        await db.close();
      },
    );

    test('current < restartGap (fresh boot) → skipped', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.securityStateDao.writeState(
        wallTimeMs: 1000,
        monotonicMs: 5000000,
        runAtMs: 1000,
      );
      final svc = _svc(
        db,
        checks: {SecurityCheck.monotonicRollback},
        restartGapMs: 600000,
        monotonicGetter: () async => 5000, // < 600000 → device just booted
      );
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });

    test('monotonicGetter returns null (channel absent) → skipped', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.securityStateDao.writeState(
        wallTimeMs: 1000,
        monotonicMs: 5000000,
        runAtMs: 1000,
      );
      final svc = _svc(
        db,
        checks: {SecurityCheck.monotonicRollback},
        monotonicGetter: () async => null,
      );
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });

    test('no prior monotonic state → skipped', () async {
      final db = await AppDatabase.inMemoryDatabase();
      // No prior writeState call → last_monotonic_ms is null
      final svc = _svc(
        db,
        checks: {SecurityCheck.monotonicRollback},
        monotonicGetter: () async => 1000000,
      );
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });
  });

  // ── server time anchor ─────────────────────────────────────────────────────

  group('serverTimeAnchor check', () {
    test('device time is before max cursor.modified → throws', () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Insert a cursor 2 hours in the future.
      final futureServer = DateTime.now().toUtc().add(const Duration(hours: 2));
      final cursorJson = jsonEncode({
        'modified': futureServer
            .toIso8601String()
            .replaceFirst('T', ' ')
            .substring(0, 19),
        'name': 'SRV-001',
        'complete': true,
      });
      await db.rawDatabase.insert('doctype_meta', {
        'doctype': 'TestDoctype',
        'isMobileForm': 0,
        'metaJson': '{}',
        'last_ok_cursor': cursorJson,
      });
      final svc = _svc(db, checks: {SecurityCheck.serverTimeAnchor});
      await expectLater(
        svc.runChecks(),
        throwsA(
          isA<SecurityCannotBeAssuredException>().having(
            (e) => e.failedChecks,
            'failedChecks',
            contains(SecurityCheck.serverTimeAnchor),
          ),
        ),
      );
      await db.close();
    });

    test('no cursors exist → skipped (never synced)', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(db, checks: {SecurityCheck.serverTimeAnchor});
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });

    test('cursor within tolerance window → no throw', () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Cursor only ~1 min in the future — inside the default 5 min tolerance,
      // so normal latency / clock skew must NOT trigger a block.
      final slightlyFuture = DateTime.now().toUtc().add(
        const Duration(minutes: 1),
      );
      final cursorJson = jsonEncode({
        'modified': slightlyFuture
            .toIso8601String()
            .replaceFirst('T', ' ')
            .substring(0, 19),
        'name': 'SRV-003',
        'complete': true,
      });
      await db.rawDatabase.insert('doctype_meta', {
        'doctype': 'TestDoctype',
        'isMobileForm': 0,
        'metaJson': '{}',
        'last_ok_cursor': cursorJson,
      });
      final svc = _svc(db, checks: {SecurityCheck.serverTimeAnchor});
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });

    test('cursor older than now → no throw', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final pastServer = DateTime.now().toUtc().subtract(
        const Duration(hours: 1),
      );
      final cursorJson = jsonEncode({
        'modified': pastServer
            .toIso8601String()
            .replaceFirst('T', ' ')
            .substring(0, 19),
        'name': 'SRV-002',
        'complete': true,
      });
      await db.rawDatabase.insert('doctype_meta', {
        'doctype': 'TestDoctype',
        'isMobileForm': 0,
        'metaJson': '{}',
        'last_ok_cursor': cursorJson,
      });
      final svc = _svc(db, checks: {SecurityCheck.serverTimeAnchor});
      await expectLater(svc.runChecks(), completes);
      await db.close();
    });
  });

  // ── all checks accumulate ──────────────────────────────────────────────────

  group('multiple checks', () {
    test('all checks fire → failedChecks contains all of them', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final futureMs = DateTime.now().millisecondsSinceEpoch + 100000000;
      await db.securityStateDao.writeState(
        wallTimeMs: futureMs,
        monotonicMs: 5000000,
        runAtMs: futureMs,
      );
      final svc = FrappeSecurityService(
        database: db,
        enabled: true,
        checks: {
          SecurityCheck.root,
          SecurityCheck.mockLocation,
          SecurityCheck.timeRollback,
          SecurityCheck.monotonicRollback,
        },
        rootChecker: () async => true,
        locationChecker: () async => true,
        monotonicGetter: () async => 3000000,
      );
      await expectLater(
        svc.runChecks(),
        throwsA(
          isA<SecurityCannotBeAssuredException>().having(
            (e) => e.failedChecks.length,
            'failedChecks.length',
            4,
          ),
        ),
      );
      await db.close();
    });

    test('getAuditLog returns events newest-first', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = _svc(db, rootChecker: () async => true);
      try {
        await svc.runChecks();
      } on SecurityCannotBeAssuredException {
        // expected
      }
      final log = await svc.getAuditLog();
      expect(log, isNotEmpty);
      expect(log.first.checkType, SecurityCheck.root);
      await db.close();
    });
  });
}
