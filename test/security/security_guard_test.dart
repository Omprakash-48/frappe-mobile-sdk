import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/security/frappe_security_guard.dart';
import 'package:frappe_mobile_sdk/src/security/frappe_security_service.dart';
import 'package:frappe_mobile_sdk/src/security/security_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

FrappeSecurityService _svc(
  AppDatabase db, {
  bool enabled = true,
  Set<SecurityCheck> checks = const {SecurityCheck.root},
  Future<bool> Function()? rootChecker,
  Future<bool?> Function()? locationChecker,
}) => FrappeSecurityService(
  database: db,
  enabled: enabled,
  checks: checks,
  rootChecker: rootChecker ?? () async => false,
  locationChecker: locationChecker ?? () async => false,
  monotonicGetter: () async => 1000000,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    // Widget tests run under fake-async; databaseFactoryFfi delivers results
    // via isolate-port messages (real event-loop events) which fake-async
    // cannot drain. databaseFactoryFfiNoIsolate resolves via microtasks so
    // pumpAndSettle() works correctly.
    databaseFactory = databaseFactoryFfiNoIsolate;
  });

  tearDown(() => AppDatabaseTestSeam.resetSingleton());

  testWidgets('guard renders child when all checks pass', (tester) async {
    final db = await AppDatabase.inMemoryDatabase();
    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(db),
          child: const Text('protected'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsOneWidget);
    await db.close();
  });

  testWidgets('guard shows default blocking screen when root detected', (
    tester,
  ) async {
    final db = await AppDatabase.inMemoryDatabase();
    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(db, rootChecker: () async => true),
          child: const Text('protected'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Security Check Failed'), findsOneWidget);
    expect(find.text('protected'), findsNothing);
    await db.close();
  });

  testWidgets('guard shows custom blockingScreen when provided', (
    tester,
  ) async {
    final db = await AppDatabase.inMemoryDatabase();
    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(db, rootChecker: () async => true),
          blockingScreen: const Scaffold(body: Text('custom block')),
          child: const Text('protected'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('custom block'), findsOneWidget);
    expect(find.text('Security Check Failed'), findsNothing);
    await db.close();
  });

  testWidgets('guard renders child when service is disabled', (tester) async {
    final db = await AppDatabase.inMemoryDatabase();
    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(db, enabled: false, rootChecker: () async => true),
          child: const Text('protected'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsOneWidget);
    await db.close();
  });

  testWidgets(
    'guard renders child when unexpected non-security exception occurs',
    (tester) async {
      final db = await AppDatabase.inMemoryDatabase();
      await tester.pumpWidget(
        MaterialApp(
          home: FrappeSecurityGuard(
            service: _svc(
              db,
              rootChecker: () async => throw Exception('network'),
            ),
            child: const Text('protected'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('protected'), findsOneWidget);
      await db.close();
    },
  );

  testWidgets('Retry on default block screen re-runs checks and recovers', (
    tester,
  ) async {
    final db = await AppDatabase.inMemoryDatabase();
    // A transient mock-location false positive (e.g. a momentary device-state
    // flap): fails the first run, passes after. Non-root failures stay
    // retryable, so Retry must recover. (Root is deliberately not retryable —
    // see the Magisk-hide test below.)
    var firstRun = true;
    Future<bool?> flakyLocationChecker() async {
      final wasFirst = firstRun;
      firstRun = false;
      return wasFirst; // true (mocked) first, false (clean) thereafter
    }

    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(
            db,
            checks: const {SecurityCheck.mockLocation},
            locationChecker: flakyLocationChecker,
          ),
          child: const Text('protected'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Blocked on first run.
    expect(find.text('Security Check Failed'), findsOneWidget);
    expect(find.text('protected'), findsNothing);

    // Tapping Retry re-runs and now passes → protected content renders.
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('protected'), findsOneWidget);
    expect(find.text('Security Check Failed'), findsNothing);
    await db.close();
  });

  testWidgets(
    'root failure is sticky: no Retry affordance, cannot be bypassed in-process '
    '(M2: Magisk-hide)',
    (tester) async {
      final db = await AppDatabase.inMemoryDatabase();
      // Simulate an attacker who hides root after the first check (e.g. adds
      // the app to Magisk DenyList) so a re-run would pass. The guard must
      // never offer that re-run for a root verdict.
      var runCount = 0;
      Future<bool> hideRootAfterFirstRun() async {
        runCount++;
        return runCount == 1; // rooted on first check, "clean" thereafter
      }

      await tester.pumpWidget(
        MaterialApp(
          home: FrappeSecurityGuard(
            service: _svc(db, rootChecker: hideRootAfterFirstRun),
            child: const Text('protected'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Blocked, and the Retry button is absent for a root verdict.
      expect(find.text('Security Check Failed'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('protected'), findsNothing);
      // The root check only ran once — there is no in-process path to re-run it.
      expect(runCount, 1);
      await db.close();
    },
  );

  testWidgets('blocking screen lists each failed check name', (tester) async {
    final db = await AppDatabase.inMemoryDatabase();
    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(db, rootChecker: () async => true),
          child: const Text('protected'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Default screen shows a human-readable label for the root check.
    expect(find.textContaining('rooted'), findsOneWidget);
    await db.close();
  });
}
