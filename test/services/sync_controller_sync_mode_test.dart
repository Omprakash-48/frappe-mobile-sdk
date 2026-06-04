import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/services/sync_controller.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    outbox = OutboxDao(db);
  });
  tearDown(() async => db.close());

  Future<Map<String, dynamic>> noopFetch(String dt, String name) async =>
      <String, dynamic>{};
  Future<void> noopApply(String dt, Map<String, dynamic> doc) async {}

  ({SyncController ctrl, List<String> calls}) build() {
    final calls = <String>[];
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {
        calls.add('pull');
        return <String>{'Deferred Doctype'};
      },
      runPullForDoctypes: (d) async => calls.add('repull:${d.join(",")}'),
      runPush: () async => calls.add('push'),
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
    return (ctrl: ctrl, calls: calls);
  }

  test('full (default) → pull, push, then re-pull deferred set', () async {
    final b = build();
    await b.ctrl.syncNow();
    expect(b.calls, ['pull', 'push', 'repull:Deferred Doctype']);
  });

  test('pushOnly → only push, never pull', () async {
    final b = build();
    await b.ctrl.syncNow(mode: SyncMode.pushOnly);
    expect(b.calls, ['push']);
  });

  test('pullOnly → only pull, never push, no deferred re-pull', () async {
    final b = build();
    await b.ctrl.syncNow(mode: SyncMode.pullOnly);
    expect(b.calls, ['pull']);
  });

  test('all modes no-op while paused', () async {
    final b = build();
    await b.ctrl.pause();
    await b.ctrl.syncNow(mode: SyncMode.full);
    await b.ctrl.syncNow(mode: SyncMode.pushOnly);
    await b.ctrl.syncNow(mode: SyncMode.pullOnly);
    expect(b.calls, isEmpty);
  });
}
