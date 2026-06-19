import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DocTypeMeta meta;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    meta = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data')],
    );
    for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doctype TEXT NOT NULL,
        mobile_uuid TEXT NOT NULL,
        operation TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending',
        error_code TEXT,
        error_message TEXT,
        payload TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  });

  tearDown(() async => db.close());

  test('pull does not overwrite a snapshot row', () async {
    // A synced record that the user re-opened and edited; held locally as a
    // snapshot (keeps its server_name).
    await db.insert('docs__customer', {
      'mobile_uuid': 'u-1',
      'server_name': 'CUST-1',
      'sync_status': 'snapshot',
      'customer_name': 'local edits',
      'local_modified': 1,
      'modified': '2020-01-01',
    });

    // Server pushes a newer value for the same record.
    await PullApply.applyPage(
      db: db,
      parentMeta: meta,
      parentTable: 'docs__customer',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'CUST-1',
          'customer_name': 'server value',
          'modified': '2030-01-01',
        },
      ],
    );

    final row = (await db.query(
      'docs__customer',
      where: 'mobile_uuid = ?',
      whereArgs: ['u-1'],
    )).single;
    expect(
      row['customer_name'],
      'local edits',
      reason: 'snapshot must be shielded',
    );
    expect(row['sync_status'], 'snapshot');
  });
}
