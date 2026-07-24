import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    dao = PendingAttachmentDao(db);
  });

  tearDown(() async => db.close());

  test('durable local copy is deleted after a successful upload', () async {
    final tmp = await Directory.systemTemp.createTemp('attach');
    final localFile = File('${tmp.path}/photo.jpg')..writeAsStringSync('IMG');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: localFile.path,
      fileName: 'photo.jpg',
    );

    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
        return {'file_url': '/files/photo.jpg', 'name': 'photo.jpg'};
      },
    );

    final results = await pipeline.uploadPendingForTopParent('P1');

    expect(results.length, 1);
    expect(localFile.existsSync(), isFalse, reason: 'copy should be reclaimed');

    final rows = await db.query('pending_attachments');
    expect(rows.single['state'], 'done');
  });
}
