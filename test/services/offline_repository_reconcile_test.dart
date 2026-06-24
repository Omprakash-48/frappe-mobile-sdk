import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  late OutboxDao outbox;

  final orderMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('customer', 'Link', options: 'Customer'),
    ],
  );

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Order',
      jsonEncode(orderMeta.toJson()),
    );

    for (final s in buildParentSchemaDDL(orderMeta, tableName: 'docs__order')) {
      await appDb.rawDatabase.execute(s);
    }

    final writer = LocalWriter(appDb.rawDatabase, (dt) async {
      final entity = await appDb.doctypeMetaDao.findByDoctype(dt);
      if (entity == null) throw StateError('no meta for $dt');
      return DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
    });
    repo = OfflineRepository(appDb, localWriter: writer);
    outbox = OutboxDao(appDb.rawDatabase);
  });

  tearDown(() async => appDb.rawDatabase.close());

  test(
    'reconcileServerSave: failed offline lineage collapses into one synced row',
    () async {
      // Arrange: a previously-saved offline doc that the push rejected.
      // docs__order has the row at mobile_uuid=X with sync_status=dirty
      // and no server_name; outbox carries one failed INSERT.
      const mobileUuid = 'X-uuid';
      await repo.saveDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': mobileUuid,
          'title': 'first try',
          'customer': 'CUST-001',
        },
      );
      // Move the auto-enqueued INSERT row to `failed` to simulate
      // PushEngine giving up after a server validation error.
      final pendings = await outbox.findByState(OutboxState.pending);
      expect(pendings.length, 1);
      await outbox.markFailed(
        pendings.first.id,
        errorCode: ErrorCode.UNKNOWN,
        errorMessage: 'LinkValidationError: Could not find Row #1',
      );

      // Act: a successful server-first retry comes back with a real
      // server name. The form code calls reconcileServerSave with the
      // SAME mobile_uuid (identity preserved).
      const serverName = 'ORDER-00001';
      await repo.reconcileServerSave(
        doctype: 'Order',
        mobileUuid: mobileUuid,
        serverName: serverName,
        serverData: {
          'name': serverName,
          'mobile_uuid': mobileUuid,
          'title': 'second try fixed',
          'customer': 'CUST-001',
          'modified': '2026-05-08 18:00:00',
        },
      );

      // Assert 1: docs__order has exactly ONE row, the original lineage,
      // now stamped synced with the server_name attached.
      final rows = await appDb.rawDatabase.query('docs__order');
      expect(rows.length, 1, reason: 'lineage must not fork into a 2nd row');
      expect(rows.first['mobile_uuid'], mobileUuid);
      expect(rows.first['server_name'], serverName);
      expect(rows.first['sync_status'], 'synced');
      expect(
        rows.first['title'],
        'second try fixed',
        reason: 'server snapshot must apply on top of the existing row',
      );

      // Assert 2: the failed outbox row is gone — the doc is on the
      // server now, no INSERT/UPDATE is owed.
      final remaining = await appDb.rawDatabase.query('outbox');
      expect(
        remaining,
        isEmpty,
        reason: 'reconcile must clear the stale failed row',
      );
    },
  );

  test('saveDocument heals parent table when meta gained a field after the '
      'table was created (no such column regression)', () async {
    // Arrange: docs__order was created from orderMeta (title, customer)
    // in setUp. The doctype then gained a new field server-side, so the
    // refreshed meta now carries `rejection_reason` — but the on-disk
    // table predates it and has no such column. This reproduces the
    // reported crash: "table docs__... has no column named rejection_reason".
    final evolvedMeta = DocTypeMeta(
      name: 'Order',
      titleField: 'title',
      fields: [
        f('title', 'Data'),
        f('customer', 'Link', options: 'Customer'),
        f('rejection_reason', 'Data'),
      ],
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Order',
      jsonEncode(evolvedMeta.toJson()),
    );

    // Act: a save carrying the new field. Before the fix this throws a
    // DatabaseException while preparing the INSERT.
    const mobileUuid = 'Z-uuid';
    await repo.saveDocument(
      doctype: 'Order',
      data: {
        'mobile_uuid': mobileUuid,
        'title': 'rejected order',
        'customer': 'CUST-003',
        'rejection_reason': 'Duplicate entry',
      },
    );

    // Assert: the table was ALTERed to add the column and the value
    // persisted onto the row.
    final cols = await appDb.rawDatabase.rawQuery(
      'PRAGMA table_info(docs__order)',
    );
    expect(
      cols.map((c) => c['name']),
      contains('rejection_reason'),
      reason: 'saveDocument must reconcile the table to the current meta',
    );
    final rows = await appDb.rawDatabase.query(
      'docs__order',
      where: 'mobile_uuid = ?',
      whereArgs: [mobileUuid],
    );
    expect(rows.length, 1);
    expect(rows.first['rejection_reason'], 'Duplicate entry');
  });

  test('invalidateMetaCacheFor lets a mid-session meta refresh take effect on '
      'the next save (no silently-dropped field)', () async {
    // Prime: first save warms OfflineRepository._metaCache with the v1
    // meta (title, customer).
    await repo.saveDocument(
      doctype: 'Order',
      data: {'mobile_uuid': 'A-uuid', 'title': 'first', 'customer': 'CUST-001'},
    );

    // The doctype gains a field server-side; a reconnect resync rewrites
    // the stored meta JSON. (checkAndSyncDoctypes does exactly this via
    // fetchAndStoreInDb.)
    final evolvedMeta = DocTypeMeta(
      name: 'Order',
      titleField: 'title',
      fields: [
        f('title', 'Data'),
        f('customer', 'Link', options: 'Customer'),
        f('rejection_reason', 'Data'),
      ],
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Order',
      jsonEncode(evolvedMeta.toJson()),
    );

    // Without invalidation, the warm cache still holds v1: the new field
    // is not in parentMeta.fields, so it is silently dropped and the
    // table is never altered.
    await repo.saveDocument(
      doctype: 'Order',
      data: {
        'mobile_uuid': 'B-uuid',
        'title': 'stale-cache save',
        'customer': 'CUST-002',
        'rejection_reason': 'dropped',
      },
    );
    var cols = (await appDb.rawDatabase.rawQuery(
      'PRAGMA table_info(docs__order)',
    )).map((c) => c['name']).toList();
    expect(
      cols,
      isNot(contains('rejection_reason')),
      reason: 'stale warm cache must still be serving v1 here',
    );

    // After invalidation the next save re-reads the fresh meta from the
    // DAO, the table self-heals, and the field persists.
    repo.invalidateMetaCacheFor('Order');
    await repo.saveDocument(
      doctype: 'Order',
      data: {
        'mobile_uuid': 'C-uuid',
        'title': 'fresh save',
        'customer': 'CUST-003',
        'rejection_reason': 'kept',
      },
    );
    cols = (await appDb.rawDatabase.rawQuery(
      'PRAGMA table_info(docs__order)',
    )).map((c) => c['name']).toList();
    expect(cols, contains('rejection_reason'));
    final rows = await appDb.rawDatabase.query(
      'docs__order',
      where: 'mobile_uuid = ?',
      whereArgs: ['C-uuid'],
    );
    expect(rows.single['rejection_reason'], 'kept');
  });

  test(
    'reconcileServerSave is a no-op on outbox for clean documents',
    () async {
      const mobileUuid = 'Y-uuid';
      await repo.saveDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': mobileUuid,
          'title': 'fresh',
          'customer': 'CUST-002',
        },
      );

      // Pretend the auto-enqueued INSERT ran cleanly: simulate
      // PushEngine.markDone by deleting the row.
      final pendings = await outbox.findByState(OutboxState.pending);
      await outbox.markDone(pendings.first.id, serverName: 'ORDER-00002');

      const serverName = 'ORDER-00002';
      await repo.reconcileServerSave(
        doctype: 'Order',
        mobileUuid: mobileUuid,
        serverName: serverName,
        serverData: {
          'name': serverName,
          'mobile_uuid': mobileUuid,
          'title': 'fresh',
          'customer': 'CUST-002',
          'modified': '2026-05-08 19:00:00',
        },
      );

      final rows = await appDb.rawDatabase.query('docs__order');
      expect(rows.length, 1);
      expect(rows.first['server_name'], serverName);
      expect(rows.first['sync_status'], 'synced');
    },
  );
}
