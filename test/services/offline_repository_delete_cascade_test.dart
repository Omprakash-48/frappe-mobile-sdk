import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Parent doctype with a child Table field, so deleteDocument's cancelled-
/// INSERT path runs its child cascade.
DocTypeMeta _orderMeta() => DocTypeMeta(
  name: 'Order',
  isTable: false,
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data'),
    DocField(fieldname: 'items', fieldtype: 'Table', options: 'Order Item'),
  ],
);

DocTypeMeta _orderItemMeta() => DocTypeMeta(
  name: 'Order Item',
  isTable: true,
  fields: [DocField(fieldname: 'qty', fieldtype: 'Int')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  Future<void> upsert(DocTypeMeta m) =>
      appDb.doctypeMetaDao.upsertMetaJson(m.name, jsonEncode(m.toJson()));

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    final localWriter = LocalWriter(appDb.rawDatabase, (dt) async {
      return dt == 'Order Item' ? _orderItemMeta() : _orderMeta();
    });
    repo = OfflineRepository(
      appDb,
      localWriter: localWriter,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: FrappeClient('http://localhost'),
      metaFetcher: (dt) async =>
          dt == 'Order Item' ? _orderItemMeta() : _orderMeta(),
    );
    await upsert(_orderMeta());
    await upsert(_orderItemMeta());
  });

  tearDown(() async => appDb.close());

  // H8 (PR#36 round-4): a REAL DatabaseException in the child cascade was
  // swallowed, committing a partial delete (parent gone, children left) and
  // reporting success. A real error must roll the whole delete back and
  // surface to the caller.
  test(
    'real child-cascade error rolls back the parent delete and throws',
    () async {
      await repo.ensureSchemaForClosure(
        metas: {'Order': _orderMeta(), 'Order Item': _orderItemMeta()},
        childDoctypes: const {'Order Item'},
      );
      final uuid = await repo.saveDocument(
        doctype: 'Order',
        data: {'title': 'A'},
      );
      final childTable = normalizeDoctypeTableName('Order Item');
      await appDb.rawDatabase.insert(childTable, {
        'mobile_uuid': 'oi-1',
        'parent_uuid': uuid,
        'parent_doctype': 'Order',
        'parentfield': 'items',
        'idx': 1,
        'qty': 1,
      });
      // Inject a non-benign DatabaseException on child delete.
      await appDb.rawDatabase.execute(
        'CREATE TRIGGER block_child_delete BEFORE DELETE ON $childTable '
        "BEGIN SELECT RAISE(ABORT, 'simulated disk failure'); END;",
      );

      await expectLater(
        repo.deleteDocument(doctype: 'Order', mobileUuid: uuid),
        throwsA(isA<DatabaseException>()),
      );

      // Whole transaction rolled back: parent row must still be present.
      final parent = await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Order'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      );
      expect(
        parent,
        isNotEmpty,
        reason: 'real cascade error must roll back parent delete',
      );
    },
  );

  // B5 (PR#36 round-4): an online delete removes the doc server-side but left
  // the local docs__ mirror behind, so it reappeared in list screens.
  // hardDeleteLocalMirror removes the parent row AND its child rows.
  test('hardDeleteLocalMirror removes parent + child rows', () async {
    await repo.ensureSchemaForClosure(
      metas: {'Order': _orderMeta(), 'Order Item': _orderItemMeta()},
      childDoctypes: const {'Order Item'},
    );
    final uuid = await repo.saveDocument(
      doctype: 'Order',
      data: {'title': 'X'},
    );
    final childTable = normalizeDoctypeTableName('Order Item');
    await appDb.rawDatabase.insert(childTable, {
      'mobile_uuid': 'oi-9',
      'parent_uuid': uuid,
      'parent_doctype': 'Order',
      'parentfield': 'items',
      'idx': 1,
      'qty': 1,
    });

    await repo.hardDeleteLocalMirror(doctype: 'Order', mobileUuid: uuid);

    final parent = await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Order'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
    final children = await appDb.rawDatabase.query(
      childTable,
      where: 'parent_uuid = ?',
      whereArgs: [uuid],
    );
    expect(parent, isEmpty, reason: 'local parent mirror must be gone');
    expect(children, isEmpty, reason: 'local child rows must be gone');
  });

  // Best-effort: a benignly absent child table must not stop the parent
  // mirror from being removed (the server delete already happened).
  test(
    'hardDeleteLocalMirror still removes parent when child table absent',
    () async {
      await repo.ensureSchemaForClosure(
        metas: {'Order': _orderMeta()},
        childDoctypes: const {},
      );
      final uuid = await repo.saveDocument(
        doctype: 'Order',
        data: {'title': 'Y'},
      );

      await repo.hardDeleteLocalMirror(doctype: 'Order', mobileUuid: uuid);

      final parent = await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Order'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      );
      expect(parent, isEmpty);
    },
  );

  // Regression guard against the wrong fix (blanket rethrow): a benignly
  // absent child table (stale build site that never migrated docs__<child>)
  // must NOT block the delete — the parent still goes, unreachable child rows
  // were garbage anyway.
  test('benignly absent child table does not block the delete', () async {
    // Create ONLY the parent table; the child docs__ table is never made.
    await repo.ensureSchemaForClosure(
      metas: {'Order': _orderMeta()},
      childDoctypes: const {},
    );
    final uuid = await repo.saveDocument(
      doctype: 'Order',
      data: {'title': 'B'},
    );

    // Must not throw even though docs__order_item does not exist.
    await repo.deleteDocument(doctype: 'Order', mobileUuid: uuid);

    final parent = await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Order'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
    expect(parent, isEmpty, reason: 'parent must be hard-deleted');
  });
}
