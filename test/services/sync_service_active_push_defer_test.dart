import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    final meta = DocTypeMeta(
      name: 'Patient',
      isTable: false,
      fields: [DocField(fieldname: 'foo', fieldtype: 'Data', label: 'Foo')],
    );
    await db.doctypeMetaDao.upsertMetaJson(
      'Patient',
      jsonEncode(meta.toJson()),
    );
  });

  tearDown(() async => await db.close());

  SyncService build({required Future<bool> Function(String)? hasActivePush}) {
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(db, client: client);
    return SyncService(client, repo, db, hasActivePush: hasActivePush);
  }

  test('defers the pull when a push is active for the doctype', () async {
    final sync = build(hasActivePush: (dt) async => true);
    final result = await sync.pullOneInternalForTest(doctype: 'Patient');
    expect(result.status, SyncStatus.deferredActivePush);
    expect(result.total, 0);
  });

  test('does NOT defer when no push is active (proceeds to pull)', () async {
    var consulted = false;
    final sync = build(
      hasActivePush: (dt) async {
        consulted = true;
        return false;
      },
    );
    // With no active push the guard does not short-circuit, so the pull
    // proceeds to the network. `_pullOneInternal` does not swallow network
    // errors (its callers do), so the unreachable localhost surfaces as a
    // throw — proving the call got PAST the defer rather than returning
    // `deferredActivePush`.
    await expectLater(
      sync.pullOneInternalForTest(doctype: 'Patient'),
      throwsA(anything),
    );
    expect(
      consulted,
      isTrue,
      reason: 'the active-push guard must be consulted before pulling',
    );
  });
}
