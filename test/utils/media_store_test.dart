import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mediastore');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  File srcFile(String name, String content) {
    final f = File('${root.path}/$name')..createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  test(
    'stageToOutbox keeps the ORIGINAL filename under a unique directory',
    () async {
      // The user's filename is the only place it survives: it cannot ride through
      // onChanged, and a uuid-named file loses it permanently. A per-pick
      // directory gives collision safety without renaming the file.
      final src = srcFile('Site Photo.jpg', 'A');
      final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');
      expect(
        staged.endsWith('/outbox/uid1/Site Photo.jpg'),
        isTrue,
        reason: staged,
      );
      expect(File(staged).readAsStringSync(), 'A');
      expect(src.existsSync(), isTrue, reason: 'staging copies, never moves');
    },
  );

  test('two picks of the same filename do not collide', () async {
    final a = await MediaStore.stageToOutbox(
      srcFile('report.pdf', 'A'),
      nameGen: () => 'uid1',
    );
    final b = await MediaStore.stageToOutbox(
      srcFile('report.pdf', 'B'),
      nameGen: () => 'uid2',
    );
    expect(a, isNot(b));
    expect(File(a).readAsStringSync(), 'A');
    expect(File(b).readAsStringSync(), 'B');
  });

  test('stageToOutbox handles a source with no extension', () async {
    final src = srcFile('noext', 'B');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');
    expect(staged.endsWith('/outbox/uid1/noext'), isTrue, reason: staged);
  });

  test('cachePathFor is deterministic and keeps the extension', () async {
    final a = await MediaStore.cachePathFor('/files/a.jpg');
    final b = await MediaStore.cachePathFor('/files/a.jpg');
    expect(a, b, reason: 'same url must always map to the same path');
    expect(a.endsWith('.jpg'), isTrue, reason: a);
    expect(a.contains('/cache/'), isTrue, reason: a);

    final c = await MediaStore.cachePathFor('/files/b.jpg');
    expect(c, isNot(a), reason: 'different urls must not collide');
  });

  test('cachePathFor borrows the extension from the source when the url '
      'has none', () async {
    final p = await MediaStore.cachePathFor(
      '/api/method/download_file?x=1',
      sourcePath: '/outbox/abc.png',
    );
    expect(p.endsWith('.png'), isTrue, reason: p);
  });

  test('moveToCache relocates the file and removes the staged copy', () async {
    final src = srcFile('IMG_2.jpg', 'C');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm1');
    final ok = await MediaStore.moveToCache(staged, '/files/x.jpg');
    expect(ok, isTrue);
    expect(File(staged).existsSync(), isFalse);
    final cached = await MediaStore.cachePathFor('/files/x.jpg');
    expect(File(cached).readAsStringSync(), 'C');
  });

  test(
    'moveToCache is idempotent when the destination already exists',
    () async {
      final src = srcFile('IMG_3.jpg', 'D');
      final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm2');
      expect(await MediaStore.moveToCache(staged, '/files/y.jpg'), isTrue);
      // Second call: the staged file is gone and the destination is present.
      // Must report success so an interrupted upload can resume.
      expect(await MediaStore.moveToCache(staged, '/files/y.jpg'), isTrue);
      final cached = await MediaStore.cachePathFor('/files/y.jpg');
      expect(File(cached).readAsStringSync(), 'D');
    },
  );

  test(
    'moveToCache returns false when neither source nor destination exists',
    () async {
      final ok = await MediaStore.moveToCache(
        '${root.path}/outbox/never.jpg',
        '/files/z.jpg',
      );
      expect(
        ok,
        isFalse,
        reason: 'cache population must not silently claim success',
      );
    },
  );

  test('storeSizeBytes counts both directories', () async {
    final src = srcFile('IMG_4.jpg', '12345');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm3');
    expect(await MediaStore.storeSizeBytes(), 5);
    await MediaStore.moveToCache(staged, '/files/v.jpg');
    expect(
      await MediaStore.storeSizeBytes(),
      5,
      reason: 'moving between dirs must not change the total',
    );
  });

  test('storeSizeBytes is 0 when nothing has been stored', () async {
    expect(await MediaStore.storeSizeBytes(), 0);
  });

  test('clearAll removes both directories', () async {
    final src = srcFile('IMG_5.jpg', 'E');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm4');
    await MediaStore.moveToCache(staged, '/files/w.jpg');
    final other = srcFile('IMG_6.jpg', 'F');
    await MediaStore.stageToOutbox(other, nameGen: () => 'm5');

    await MediaStore.clearAll();

    expect(await MediaStore.storeSizeBytes(), 0);
    expect(
      File(await MediaStore.cachePathFor('/files/w.jpg')).existsSync(),
      isFalse,
    );
  });

  test('deleteOutboxCopy removes the file and is safe when absent', () async {
    final src = srcFile('IMG_7.jpg', 'G');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm6');
    await MediaStore.deleteOutboxCopy(staged);
    expect(File(staged).existsSync(), isFalse);
    // Second call must not throw.
    await MediaStore.deleteOutboxCopy(staged);
  });
}
