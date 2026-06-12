import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/security/security_check.dart';
import 'package:frappe_mobile_sdk/src/security/security_event.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SecurityEvent _evt(
  SecurityCheck check, {
  int detectedAtMs = 1000,
  int? serverAnchorMs,
  int? lastWallMs,
  int? monotonicMs,
}) =>
    SecurityEvent(
      id: 'test-${check.name}-$detectedAtMs',
      checkType: check,
      detectedAtMs: detectedAtMs,
      wallTimeMs: detectedAtMs,
      serverAnchorMs: serverAnchorMs,
      lastWallMs: lastWallMs,
      monotonicMs: monotonicMs,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() => AppDatabaseTestSeam.resetSingleton());

  test('insert and queryNewestFirst returns the event', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityEventDao.insert(_evt(SecurityCheck.root));
    final events = await db.securityEventDao.queryNewestFirst();
    expect(events, hasLength(1));
    expect(events.first.checkType, SecurityCheck.root);
    expect(events.first.wallTimeMs, 1000);
    await db.close();
  });

  test('queryNewestFirst orders by detected_at_ms descending', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityEventDao.insert(
      _evt(SecurityCheck.root, detectedAtMs: 1000),
    );
    await db.securityEventDao.insert(
      _evt(SecurityCheck.timeRollback, detectedAtMs: 3000),
    );
    await db.securityEventDao.insert(
      _evt(SecurityCheck.mockLocation, detectedAtMs: 2000),
    );
    final events = await db.securityEventDao.queryNewestFirst();
    expect(events[0].checkType, SecurityCheck.timeRollback); // 3000
    expect(events[1].checkType, SecurityCheck.mockLocation); // 2000
    expect(events[2].checkType, SecurityCheck.root); // 1000
    await db.close();
  });

  test('queryNewestFirst respects limit', () async {
    final db = await AppDatabase.inMemoryDatabase();
    for (var i = 0; i < 5; i++) {
      await db.securityEventDao.insert(
        _evt(SecurityCheck.root, detectedAtMs: i * 100),
      );
    }
    final events = await db.securityEventDao.queryNewestFirst(limit: 2);
    expect(events, hasLength(2));
    await db.close();
  });

  test('serverAnchorMs is persisted and restored correctly', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityEventDao.insert(
      _evt(SecurityCheck.serverTimeAnchor, serverAnchorMs: 9999999),
    );
    final events = await db.securityEventDao.queryNewestFirst();
    expect(events.first.serverAnchorMs, 9999999);
    await db.close();
  });

  test('monotonicMs and lastWallMs are persisted correctly', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityEventDao.insert(
      _evt(
        SecurityCheck.monotonicRollback,
        monotonicMs: 3000000,
        lastWallMs: 5000000,
      ),
    );
    final events = await db.securityEventDao.queryNewestFirst();
    expect(events.first.monotonicMs, 3000000);
    expect(events.first.lastWallMs, 5000000);
    await db.close();
  });
}
