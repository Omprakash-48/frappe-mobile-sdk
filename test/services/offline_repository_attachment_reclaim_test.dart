import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  isTable: false,
  fields: [DocField(fieldname: 'photo', fieldtype: 'Attach Image')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  late Directory root;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      appDb,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
    root = await Directory.systemTemp.createTemp('reclaim');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
    await appDb.close();
  });

  /// A staged file, created the way `stageToOutbox` would leave it.
  Future<String> stage(String name) async {
    final src = File('${root.path}/$name')..createSync(recursive: true);
    await src.writeAsString('bytes');
    return MediaStore.stageToOutbox(src);
  }

  test('reclaims a staged file no queued attachment references', () async {
    final staged = await stage('unsaved.jpg');
    expect(File(staged).existsSync(), isTrue);

    await repo.reclaimDiscardedAttachment(staged);

    expect(
      File(staged).existsSync(),
      isFalse,
      reason: 'a pick discarded before any save is nobody else\'s file',
    );
  });

  test(
    'leaves a staged file a queued attachment row still references',
    () async {
      // The sequence this guards: offline pick -> Save (LocalWriter swaps the
      // path for `pending:<id>` in the COLUMN and enqueues this row) -> the
      // form stays open, so the field still holds the raw staged path -> the
      // user taps discard. Deleting here strands the queued upload on a file
      // that no longer exists, and the push blocks the document for a human.
      final staged = await stage('saved.jpg');
      await PendingAttachmentDao(appDb.rawDatabase).enqueue(
        parentDoctype: 'Visit',
        parentUuid: 'uuid-1',
        parentFieldname: 'photo',
        topParentUuid: 'uuid-1',
        topParentDoctype: 'Visit',
        localPath: staged,
        fileName: 'saved.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 5,
      );

      await repo.reclaimDiscardedAttachment(staged);

      expect(
        File(staged).existsSync(),
        isTrue,
        reason: 'the queued row owns these bytes until the next save drops it',
      );
    },
  );
}
