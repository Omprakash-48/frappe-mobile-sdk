// `cachePathFor` builds a filename from the url's extension, and a url is not a
// path: `p.extension` takes everything after the last dot of the last segment,
// query string included. For the cloud-proxy shape `media_store.dart` names by
// vendor, a signed key landed in the filename and blew past `NAME_MAX` (255) —
// the write threw, `MediaResolver.resolve`'s catch-all swallowed it, no
// `media_cache` row was written, and the attachment re-downloaded on every view
// forever. Round-4 review M1.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('media_store_cache_path');
    MediaStore.overrideRootForTest(tmp.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// ext4/f2fs cap a single filename at 255 BYTES, not characters.
  const nameMax = 255;

  test('a signed-key proxy url yields a filename within NAME_MAX', () async {
    final url =
        '/api/method/multi_cloud_storage.download'
        '?file=survey.pdf&key=${'A' * 300}';

    final path = await MediaStore.cachePathFor(url);
    final name = p.basename(path);

    expect(
      name.length,
      lessThanOrEqualTo(nameMax),
      reason: 'a 373-char name is ENAMETOOLONG and the write is swallowed',
    );
    // The query must not survive into the filename in any form.
    expect(name, isNot(contains('key=')));
    expect(name, isNot(contains('&')));
    expect(name, isNot(contains('?')));
    // Bare digest: correct and collision-free. Truncating the extension would
    // have kept it wrong, just shorter.
    expect(name, hasLength(64));
  });

  test('a legitimate extension is still kept, and lowercased', () async {
    expect(
      p.basename(await MediaStore.cachePathFor('/files/report.pdf')),
      endsWith('.pdf'),
    );
    expect(
      p.basename(await MediaStore.cachePathFor('/files/SCAN.PNG')),
      endsWith('.png'),
    );
  });

  test('the url keeps priority; sourcePath only fills a genuine gap', () async {
    // Extension-less url — the case the sourcePath fallback exists for.
    final viaSource = await MediaStore.cachePathFor(
      '/api/method/frappe.core.doctype.file.file.download_file',
      sourcePath: '/outbox/x/staged.jpg',
    );
    expect(p.basename(viaSource), endsWith('.jpg'));

    // A mangled url extension must not be preferred over a clean source one.
    final mangled = await MediaStore.cachePathFor(
      '/api/method/proxy.download?file=a.pdf&key=${'B' * 300}',
      sourcePath: '/outbox/x/staged.jpg',
    );
    expect(p.basename(mangled).length, lessThanOrEqualTo(nameMax));
    expect(p.basename(mangled), endsWith('.jpg'));
  });

  test('the path is writable — the real end-to-end assertion', () async {
    final url = '/api/method/proxy.download?file=a.pdf&key=${'C' * 300}';
    final dest = File(await MediaStore.cachePathFor(url));
    await dest.parent.create(recursive: true);
    // Before the fix this threw ENAMETOOLONG (errno 36 on ext4).
    await dest.writeAsBytes(<int>[1, 2, 3], flush: true);
    expect(await dest.exists(), isTrue);
    expect(await dest.length(), 3);
  });
}
