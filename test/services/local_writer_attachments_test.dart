import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late LocalWriter writer;

  final parentMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('photo', 'Attach'),
      f('scan', 'Attach Image'),
      f('server_shot', 'Attach'), // already a server URL — must pass through
      f('items', 'Table', options: 'Order Item'),
    ],
  );
  final childMeta = DocTypeMeta(
    name: 'Order Item',
    isTable: true,
    fields: [f('label', 'Data'), f('receipt', 'Attach Image')],
  );

  Future<DocTypeMeta> metaFn(String dt) async {
    if (dt == 'Order') return parentMeta;
    if (dt == 'Order Item') return childMeta;
    throw StateError('unexpected meta lookup: $dt');
  }

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    for (final s in buildParentSchemaDDL(
      parentMeta,
      tableName: 'docs__order',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__order_item',
    )) {
      await db.execute(s);
    }
    writer = LocalWriter(db, metaFn);
  });

  tearDown(() async => db.close());

  Map<String, dynamic> saveData() => {
    'mobile_uuid': 'p-uuid-1',
    'title': 'offline order',
    'photo': '/data/user/0/app/cache/IMG_1.jpg',
    'scan': '/data/user/0/app/mform_attachments/a.png',
    'server_shot': '/files/already_uploaded.png',
    'items': [
      {
        'mobile_uuid': 'C1',
        'label': 'row0',
        'receipt': '/data/user/0/app/cache/receipt0.jpg',
      },
    ],
  };

  test(
    'local attach values are enqueued and rewritten to pending markers',
    () async {
      await writer.writeParent(parentDoctype: 'Order', data: saveData());

      final parent = (await db.query('docs__order')).single;
      expect((parent['photo'] as String).startsWith('pending:'), isTrue);
      expect((parent['scan'] as String).startsWith('pending:'), isTrue);
      // server URL untouched
      expect(parent['server_shot'], '/files/already_uploaded.png');

      final child = (await db.query('docs__order_item')).single;
      expect((child['receipt'] as String).startsWith('pending:'), isTrue);
      expect(child['mobile_uuid'], 'C1');

      final pend = await db.query('pending_attachments', orderBy: 'id ASC');
      expect(pend.length, 3); // photo, scan (parent), receipt (child)

      final photoRow = pend.firstWhere((r) => r['parent_fieldname'] == 'photo');
      expect(photoRow['parent_uuid'], 'p-uuid-1');
      expect(photoRow['parent_doctype'], 'Order');
      expect(photoRow['top_parent_uuid'], 'p-uuid-1');
      expect(photoRow['top_parent_doctype'], 'Order');
      expect(photoRow['local_path'], '/data/user/0/app/cache/IMG_1.jpg');

      final receiptRow = pend.firstWhere(
        (r) => r['parent_fieldname'] == 'receipt',
      );
      expect(receiptRow['parent_uuid'], 'C1');
      expect(receiptRow['parent_doctype'], 'Order Item');
      expect(receiptRow['top_parent_uuid'], 'p-uuid-1');
      expect(receiptRow['top_parent_doctype'], 'Order');
      expect(receiptRow['local_path'], '/data/user/0/app/cache/receipt0.jpg');

      // the stored parent marker must reference the parent's own pending row
      expect(parent['photo'], 'pending:${photoRow['id']}');
    },
  );

  test(
    're-saving with the same local files does not duplicate pending rows',
    () async {
      await writer.writeParent(parentDoctype: 'Order', data: saveData());
      await writer.writeParent(parentDoctype: 'Order', data: saveData());

      final pend = await db.query('pending_attachments');
      expect(pend.length, 3); // still 3, not 6
    },
  );

  test(
    're-saving with pending markers leaves them untouched (no re-enqueue)',
    () async {
      await writer.writeParent(parentDoctype: 'Order', data: saveData());
      final parent = (await db.query('docs__order')).single;
      final child = (await db.query('docs__order_item')).single;

      // second save carries the markers back (what a form edit round-trip does)
      final data2 = saveData();
      data2['photo'] = parent['photo'];
      data2['scan'] = parent['scan'];
      (data2['items'] as List)[0]['receipt'] = child['receipt'];

      await writer.writeParent(parentDoctype: 'Order', data: data2);

      final pend = await db.query('pending_attachments');
      expect(pend.length, 3); // unchanged
      final parent2 = (await db.query('docs__order')).single;
      expect(
        parent2['photo'],
        parent['photo'],
      ); // no 'pending:pending:' corruption
    },
  );

  test('enqueue records size, mime and the ORIGINAL filename', () async {
    // Staged files keep the user's filename (uniqueness lives in the parent
    // directory), so the name survives all the way to the server instead of
    // every upload landing as an opaque uuid.
    final root = await Directory.systemTemp.createTemp('lwmeta');
    MediaStore.overrideRootForTest(root.path);
    addTearDown(() async {
      MediaStore.overrideRootForTest(null);
      if (await root.exists()) await root.delete(recursive: true);
    });

    final picked = File('${root.path}/Site Photo.jpg')
      ..writeAsStringSync('0123456789');
    final staged = await MediaStore.stageToOutbox(
      picked,
      nameGen: () => 'uid1',
    );

    final data = saveData();
    data['photo'] = staged;
    await writer.writeParent(parentDoctype: 'Order', data: data);

    final row = (await db.query(
      'pending_attachments',
      where: 'parent_fieldname = ?',
      whereArgs: ['photo'],
    )).single;
    expect(row['file_name'], 'Site Photo.jpg');
    expect(row['size_bytes'], 10);
    expect(row['mime_type'], 'image/jpeg');
    expect(row['local_path'], staged);
  });

  test(
    'an unknown extension leaves mime_type null rather than guessing',
    () async {
      final root = await Directory.systemTemp.createTemp('lwmeta2');
      MediaStore.overrideRootForTest(root.path);
      addTearDown(() async {
        MediaStore.overrideRootForTest(null);
        if (await root.exists()) await root.delete(recursive: true);
      });

      final picked = File('${root.path}/blob.xyzzy')..writeAsStringSync('ab');
      final staged = await MediaStore.stageToOutbox(
        picked,
        nameGen: () => 'uid2',
      );
      final data = saveData();
      data['photo'] = staged;
      await writer.writeParent(parentDoctype: 'Order', data: data);

      final row = (await db.query(
        'pending_attachments',
        where: 'parent_fieldname = ?',
        whereArgs: ['photo'],
      )).single;
      expect(row['mime_type'], isNull);
      expect(row['size_bytes'], 2);
    },
  );
}
