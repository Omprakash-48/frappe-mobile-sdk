// The viewer scratch cache (`frappe_attachments/`) lives under the OS temp root,
// NOT under MediaStore's own root — so `clearAll`, `sweepOrphans` and `usage`,
// which all walk that root, could never reach it. Nothing wiped it, including
// `logout(clearDatabase: true)`, whose whole purpose is that decrypted copies of
// private attachments are gone. Round-4 review M4.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_paths.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory storeRoot;
  late Directory tempRoot;

  setUp(() async {
    storeRoot = await Directory.systemTemp.createTemp('ms_store');
    tempRoot = await Directory.systemTemp.createTemp('ms_temp');
    MediaStore.overrideRootForTest(storeRoot.path);
    MediaStore.overrideTempRootForTest(tempRoot.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    MediaStore.overrideTempRootForTest(null);
    for (final d in [storeRoot, tempRoot]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  Future<File> stageViewerFile(String name, int bytes) async {
    final f = File(p.join(await MediaStore.viewerTempDir(), name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(List.filled(bytes, 0), flush: true);
    return f;
  }

  test(
    'the viewer cache is under the OS temp root, not the store root',
    () async {
      final dir = await MediaStore.viewerTempDir();
      expect(p.basename(dir), attachmentTempDirName);
      expect(p.isWithin(tempRoot.path, dir), isTrue);
      expect(
        p.isWithin(storeRoot.path, dir),
        isFalse,
        reason:
            'if it were inside the store root, clearAll would already cover it',
      );
    },
  );

  test('clearAll wipes it — this is the logout wipe', () async {
    final f = await stageViewerFile('a.pdf', 128);
    expect(await f.exists(), isTrue);

    await MediaStore.clearAll();

    expect(
      await f.exists(),
      isFalse,
      reason: 'a decrypted private attachment must not survive logout',
    );
  });

  test('usage reports its bytes, and counts them in the total', () async {
    await stageViewerFile('a.pdf', 300);
    await stageViewerFile('nested/b.pdf', 200);

    final usage = await MediaStore.usage(<String>{});

    expect(usage.viewerTempBytes, 500);
    expect(usage.totalBytes, greaterThanOrEqualTo(500));
  });

  test('the orphan sweep leaves it alone', () async {
    final f = await stageViewerFile('open-in-a-viewer.pdf', 64);

    // Nothing in pending_attachments ever points here, so a reference-based
    // sweep would see every file as orphaned and be free to delete one a
    // viewer currently holds open. It must not participate.
    await MediaStore.sweepOrphans(<String>{});

    expect(await f.exists(), isTrue);
  });

  test('a missing directory reports zero rather than throwing', () async {
    expect(await MediaStore.viewerTempBytes(), 0);
    await MediaStore.clearViewerTempCache(); // idempotent
    expect(await MediaStore.viewerTempBytes(), 0);
  });

  test(
    'the download target AttachField builds is inside the wiped dir',
    () async {
      // Wiring assertion, not a behaviour one. `AttachField` used to build this
      // path from its own `getTemporaryDirectory()` + `attachmentTempDirName`,
      // which produced the same string as `viewerTempDir()` — but by coincidence,
      // not by construction. Two independent spellings of a path where one side
      // deletes what the other writes is exactly the divergence that caused the
      // `moveToCache` / `resolve` cache-path bug in this release. It now goes
      // through MediaStore, so the writer and the wipe cannot drift.
      final target = File(
        p.join(
          await MediaStore.viewerTempDir(),
          attachmentTempFileName('/files/report.pdf', 'report.pdf'),
        ),
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(const <int>[1, 2, 3], flush: true);

      // It is measured...
      expect(await MediaStore.viewerTempBytes(), 3);
      // ...and it is wiped.
      await MediaStore.clearAll();
      expect(await target.exists(), isFalse);
    },
  );

  test('the capture marker is wiped by clearAll, at its unchanged path', () async {
    // The marker names the field that launched the camera. Left behind, an
    // interrupted capture could be handed to a field in the NEXT session — on a
    // shared device, a different user's. Its 30-minute staleness window bounds
    // that but does not close it: a logout inside the window leaves it live.
    final marker = File(await MediaStore.captureMarkerPath());

    // Path is deliberately UNCHANGED: the temp ROOT, not inside
    // frappe_attachments/. Moving it would orphan a marker written by the
    // version being upgraded from.
    expect(p.basename(marker.path), cameraCaptureMarkerFileName);
    expect(p.dirname(marker.path), tempRoot.path);
    expect(
      p.isWithin(await MediaStore.viewerTempDir(), marker.path),
      isFalse,
      reason: 'it is a sibling of the viewer cache, not inside it',
    );

    await marker.writeAsString('Attach Image/photo', flush: true);
    await MediaStore.clearAll();
    expect(await marker.exists(), isFalse);
  });

  test('clearAll with no marker present does not throw', () async {
    await MediaStore.clearAll();
    expect(await File(await MediaStore.captureMarkerPath()).exists(), isFalse);
  });

  test(
    'clearMediaCache reclaims it too, so the reported total can move',
    () async {
      // `viewerTempBytes` is counted in `MediaStoreUsage.totalBytes`. If the only
      // path that reclaimed it were logout, a host showing that figure beside a
      // "Clear cached media" button would offer a control that cannot move the
      // number it displays. Round-4 follow-up.
      final f = File(p.join(await MediaStore.viewerTempDir(), 'a.pdf'));
      await f.parent.create(recursive: true);
      await f.writeAsBytes(List.filled(120, 0), flush: true);
      expect((await MediaStore.usage(<String>{})).viewerTempBytes, 120);

      await MediaStore.clearCache();

      expect(await f.exists(), isFalse);
      expect((await MediaStore.usage(<String>{})).viewerTempBytes, 0);
    },
  );

  test('clearCache still leaves outbox alone', () async {
    // The safety property clearCache advertises must survive the addition.
    final staged = File(p.join(storeRoot.path, 'outbox', 'x', 'pick.jpg'));
    await staged.parent.create(recursive: true);
    await staged.writeAsBytes(const <int>[9], flush: true);

    await MediaStore.clearCache();

    expect(
      await staged.exists(),
      isTrue,
      reason: 'a staged file is the only copy — clearCache must never take it',
    );
  });
}
