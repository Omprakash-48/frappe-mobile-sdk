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
}) => FrappeSecurityService(
  database: db,
  enabled: enabled,
  checks: checks,
  rootChecker: rootChecker ?? () async => false,
  locationChecker: () async => false,
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
    // Fails the first run (rooted), passes every run after — simulating a
    // transient false positive that clears on retry.
    var firstRun = true;
    Future<bool> flakyRootChecker() async {
      final wasFirst = firstRun;
      firstRun = false;
      return wasFirst;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: FrappeSecurityGuard(
          service: _svc(db, rootChecker: flakyRootChecker),
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
