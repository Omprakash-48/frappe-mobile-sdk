import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('syncStatusOverride forces sync_status verbatim', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    final meta = DocTypeMeta(
      name: 'Customer',
      autoname: 'format:CUST-{#####}',
      fields: [f('customer_name', 'Data')],
    );
    for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    final writer = LocalWriter(db, (_) async => meta);

    await db.transaction((txn) async {
      await writer.writeParentInTxn(
        txn: txn,
        parentDoctype: 'Customer',
        mobileUuid: 'u-1',
        data: {'mobile_uuid': 'u-1', 'customer_name': 'ACME'},
        syncOp: 'INSERT',
        parentMeta: meta,
        syncStatusOverride: 'snapshot',
      );
    });

    final row = (await db.query(
      'docs__customer',
      where: 'mobile_uuid = ?',
      whereArgs: ['u-1'],
    )).single;
    expect(row['sync_status'], 'snapshot');

    await db.close();
  });

  test(
    'without override, syncOp still yields dirty (unchanged behavior)',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      final meta = DocTypeMeta(
        name: 'Customer',
        autoname: 'format:CUST-{#####}',
        fields: [f('customer_name', 'Data')],
      );
      for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
        await db.execute(s);
      }
      final writer = LocalWriter(db, (_) async => meta);

      await db.transaction((txn) async {
        await writer.writeParentInTxn(
          txn: txn,
          parentDoctype: 'Customer',
          mobileUuid: 'u-2',
          data: {'mobile_uuid': 'u-2', 'customer_name': 'ACME'},
          syncOp: 'INSERT',
          parentMeta: meta,
        );
      });

      final row = (await db.query(
        'docs__customer',
        where: 'mobile_uuid = ?',
        whereArgs: ['u-2'],
      )).single;
      expect(row['sync_status'], 'dirty');

      await db.close();
    },
  );
}
