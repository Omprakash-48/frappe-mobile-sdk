import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';

/// The media store lives OUTSIDE SQLite, so `AppDatabase.clearAllData()` —
/// which drops `media_cache` and `pending_attachments` — does not touch the
/// files. Without an explicit wipe, one user's private survey photos stay
/// readable on a shared device after the next sign-in.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wipe');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<void> seedBothDirectories() async {
    final staged = File('${root.path}/pick.jpg')..writeAsStringSync('STAGED');
    final path = await MediaStore.stageToOutbox(staged, nameGen: () => 'uid1');
    // One file stays staged; another is promoted into the cache.
    final second = File('${root.path}/pick2.jpg')..writeAsStringSync('CACHED');
    final path2 = await MediaStore.stageToOutbox(second, nameGen: () => 'uid2');
    await MediaStore.moveToCache(path2, '/files/cached.jpg');
    expect(File(path).existsSync(), isTrue);
    expect(
      File(await MediaStore.cachePathFor('/files/cached.jpg')).existsSync(),
      isTrue,
    );
  }

  test('clearAll removes staged AND cached media', () async {
    await seedBothDirectories();

    await MediaStore.clearAll();

    expect(await MediaStore.storeSizeBytes(), 0);
    expect(
      File(await MediaStore.cachePathFor('/files/cached.jpg')).existsSync(),
      isFalse,
      reason: 'a cached private file must not survive logout',
    );
    expect(
      Directory('${root.path}/mform_attachments').existsSync(),
      isFalse,
      reason: 'the whole store goes, not just its contents',
    );
  });

  test('clearAll is safe when nothing has been stored', () async {
    await MediaStore.clearAll();
    expect(await MediaStore.storeSizeBytes(), 0);
  });

  test('clearAll is idempotent', () async {
    await seedBothDirectories();
    await MediaStore.clearAll();
    await MediaStore.clearAll();
    expect(await MediaStore.storeSizeBytes(), 0);
  });

  test(
    'storeSizeBytes counts staged files nested under their pick directory',
    () async {
      // Staged files sit at outbox/<uid>/<name>, so a non-recursive walk would
      // report 0 and make the host's usage display permanently wrong.
      final src = File('${root.path}/a.bin')
        ..writeAsBytesSync(List.filled(64, 0));
      await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');
      expect(await MediaStore.storeSizeBytes(), 64);
    },
  );
}
