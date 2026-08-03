import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// M1 (PR #80): the glue that makes the meta-refresh → cache-invalidation path
/// work end-to-end lives in a single assignment
/// (`_metaService.onMetaRefreshed = _repository.invalidateMetaCacheFor`).
/// Both sides are unit-tested in isolation, but nothing asserted that FrappeSDK
/// actually connects them — if that line were dropped or mis-ordered the
/// integration would silently break with no test signal. This closes that gap.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('FrappeSDK wires MetaService.onMetaRefreshed to '
      'OfflineRepository.invalidateMetaCacheFor (a meta refresh evicts the '
      'offline save cache)', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final sdk = FrappeSDK.forTesting(
      'http://localhost',
      db,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    );

    // The glue line itself — removing it silently breaks the
    // refresh→invalidate path, so assert it is wired at all.
    expect(sdk.meta.onMetaRefreshed, isNotNull);

    // v1 meta (one field). Prime the repository's per-doctype meta cache
    // with v1 via a real offline save.
    final v1 = DocTypeMeta(
      name: 'Customer',
      fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
    );
    await db.doctypeMetaDao.upsertMetaJson('Customer', jsonEncode(v1.toJson()));
    await sdk.repository.ensureSchemaForClosure(
      metas: {'Customer': v1},
      childDoctypes: const {},
    );
    await sdk.repository.saveDocument(
      doctype: 'Customer',
      data: {'mobile_uuid': 'c1', 'customer_name': 'Acme'},
    );

    // Server adds a field; persist v2, then fire the refresh hook (the
    // wiring under test). If it targets invalidateMetaCacheFor the repo's
    // cached v1 is evicted; otherwise the next save keeps serving v1.
    final v2 = DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'customer_name', fieldtype: 'Data'),
        DocField(fieldname: 'phone', fieldtype: 'Data'),
      ],
    );
    await db.doctypeMetaDao.upsertMetaJson('Customer', jsonEncode(v2.toJson()));
    sdk.meta.onMetaRefreshed!('Customer');

    // The next save must read v2 (cache evicted) → table reconciled to add
    // the new column, and the new field persists.
    await sdk.repository.saveDocument(
      doctype: 'Customer',
      data: {'mobile_uuid': 'c2', 'customer_name': 'Beta', 'phone': '999'},
    );
    final cols = await db.rawDatabase.rawQuery(
      'PRAGMA table_info(docs__customer)',
    );
    expect(
      cols.map((c) => c['name']),
      contains('phone'),
      reason: 'refresh hook must evict the repo cache → table reconciled to v2',
    );
    final rows = await db.rawDatabase.query(
      'docs__customer',
      where: 'mobile_uuid = ?',
      whereArgs: ['c2'],
    );
    expect(rows.first['phone'], '999');

    await sdk.dispose();
    await db.close();
  });
}
