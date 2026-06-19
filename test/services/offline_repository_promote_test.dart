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

DocTypeMeta _customerMeta() => DocTypeMeta(
  name: 'Customer',
  isTable: false,
  fields: [
    DocField(fieldname: 'customer_name', fieldtype: 'Data'),
    DocField(fieldname: 'amount', fieldtype: 'Currency'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    final localWriter = LocalWriter(
      appDb.rawDatabase,
      (_) async => _customerMeta(),
    );
    repo = OfflineRepository(
      appDb,
      localWriter: localWriter,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: FrappeClient('http://localhost'),
      metaFetcher: (_) async => _customerMeta(),
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Customer',
      jsonEncode(_customerMeta().toJson()),
    );
    await repo.ensureSchemaForClosure(
      metas: {'Customer': _customerMeta()},
      childDoctypes: const {},
    );
  });

  tearDown(() async => appDb.close());

  test(
    'a snapshot is never selected by the push drain (no pending outbox)',
    () async {
      final uuid = await repo.saveSnapshot(
        doctype: 'Customer',
        data: {'customer_name': 'Half'},
      );
      final pending = await appDb.rawDatabase.query(
        'outbox',
        where: "mobile_uuid = ? AND state = 'pending'",
        whereArgs: [uuid],
      );
      expect(pending, isEmpty);
    },
  );

  test(
    'saveDocument promotes an existing snapshot to dirty + enqueues',
    () async {
      final uuid = await repo.saveSnapshot(
        doctype: 'Customer',
        data: {'customer_name': 'Half'},
      );
      // Sanity: parked as snapshot, nothing enqueued.
      expect(
        await appDb.rawDatabase.query(
          'outbox',
          where: 'mobile_uuid = ?',
          whereArgs: [uuid],
        ),
        isEmpty,
      );

      // User completes the form and taps Save (the real, validating path).
      await repo.saveDocument(
        doctype: 'Customer',
        data: {'mobile_uuid': uuid, 'customer_name': 'Complete', 'amount': 50},
      );

      final row = (await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Customer'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).single;
      expect(row['sync_status'], 'dirty');
      expect(row['customer_name'], 'Complete');

      final outbox = await appDb.rawDatabase.query(
        'outbox',
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      );
      expect(
        outbox,
        isNotEmpty,
        reason: 'promotion enqueues exactly when saveDocument runs',
      );
      expect(outbox.first['operation'], 'INSERT');
    },
  );
}
