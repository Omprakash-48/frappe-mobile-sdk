// The whole bug, composed, on the real save path.
//
// Offline pick stages a file and the field holds its raw path. Saving does two
// things the UI never learns about: `LocalWriter` enqueues a
// `pending_attachments` row owning that file, and rewrites the COLUMN to
// `pending:<id>`. The open form keeps the raw path — `hasInteractedByUser` pins
// it, deliberately, so an explicit clear survives an async document load — so
// the value the discard button hands to the reclaim is a staged path that a
// committed queue row now owns.
//
// `MediaStore.discardValue` deletes it: its "a raw staged path was never saved"
// reasoning is about the column, and the column is not what it was given. The
// push then uploads `fileFromPath` on a file that no longer exists, which is
// not a terminal error, so it exhausts the backoff, marks the row failed and
// blocks the document — and push does not auto-retry.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_paths.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  isTable: false,
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data'),
    DocField(fieldname: 'photo', fieldtype: 'Attach Image'),
  ],
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
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Visit',
      jsonEncode(_meta().toJson()),
    );
    await repo.ensureSchemaForClosure(
      metas: {'Visit': _meta()},
      childDoctypes: const {},
    );
    root = await Directory.systemTemp.createTemp('discard_after_save');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
    await appDb.close();
  });

  test('discarding after a save keeps the file the queue row owns', () async {
    // 1. Offline pick: the file is staged and the field holds its raw path.
    final src = File('${root.path}/site.jpg')..createSync(recursive: true);
    await src.writeAsString('PHOTO');
    final stagedPath = await MediaStore.stageToOutbox(src);
    expect(await MediaStore.isStagedPath(stagedPath), isTrue);

    // 2. Save. LocalWriter enqueues the row and rewrites the column.
    final uuid = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'Site A', 'photo': stagedPath},
    );
    final saved = await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Visit'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
    expect(
      saved.single['photo'],
      startsWith(kPendingMarkerPrefix),
      reason: 'the column moved on; the open form did not',
    );
    final queued = await appDb.rawDatabase.query('pending_attachments');
    expect(queued.single['local_path'], stagedPath);

    // 3. The form is still open, so the discard button hands over the RAW
    //    staged path — not the marker the column now holds.
    await repo.reclaimDiscardedAttachment(stagedPath);

    expect(
      File(stagedPath).existsSync(),
      isTrue,
      reason: 'deleting this strands the queued upload and blocks the document',
    );
  });

  test('discarding a pick that was never saved still reclaims it', () async {
    // The counterpart. Nothing owns these bytes, and refusing to delete them
    // would trade the bug for a leak on the far more common path.
    final src = File('${root.path}/scratch.jpg')..createSync(recursive: true);
    await src.writeAsString('PHOTO');
    final stagedPath = await MediaStore.stageToOutbox(src);

    await repo.reclaimDiscardedAttachment(stagedPath);

    expect(File(stagedPath).existsSync(), isFalse);
  });
}
