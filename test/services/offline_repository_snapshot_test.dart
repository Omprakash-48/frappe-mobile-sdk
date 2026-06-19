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

  test('saveSnapshot writes a snapshot row and NO outbox row', () async {
    final uuid = await repo.saveSnapshot(
      doctype: 'Customer',
      data: {'customer_name': 'Half typed'},
    );
    expect(uuid, isNotEmpty);

    final docs = await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Customer'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
    expect(docs.length, 1);
    expect(docs[0]['sync_status'], 'snapshot');
    expect(docs[0]['server_name'], isNull);
    expect(docs[0]['customer_name'], 'Half typed');

    final outbox = await appDb.rawDatabase.query(
      'outbox',
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
    expect(outbox, isEmpty, reason: 'a snapshot must never enqueue');
  });

  test(
    'saveSnapshot reuses a provided mobile_uuid (idempotent edit)',
    () async {
      final first = await repo.saveSnapshot(
        doctype: 'Customer',
        data: {'mobile_uuid': 'fixed-uuid', 'customer_name': 'A'},
      );
      final second = await repo.saveSnapshot(
        doctype: 'Customer',
        data: {'mobile_uuid': 'fixed-uuid', 'customer_name': 'B'},
      );
      expect(first, 'fixed-uuid');
      expect(second, 'fixed-uuid');

      final docs = await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Customer'),
        where: 'mobile_uuid = ?',
        whereArgs: ['fixed-uuid'],
      );
      expect(docs.length, 1);
      expect(docs[0]['customer_name'], 'B');
      expect(docs[0]['sync_status'], 'snapshot');
    },
  );
}
