import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_storage.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('appdocs');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('copies file into mform_attachments preserving extension', () async {
    final src = File('${tmp.path}/cache_IMG_1.jpg')..writeAsStringSync('BYTES');

    final out = await copyToAttachmentStore(src, nameGen: () => 'fixed');

    expect(out, '${tmp.path}/mform_attachments/fixed.jpg');
    expect(File(out).existsSync(), isTrue);
    expect(File(out).readAsStringSync(), 'BYTES');
  });

  test('handles a source with no extension', () async {
    final src = File('${tmp.path}/noext')..writeAsStringSync('X');

    final out = await copyToAttachmentStore(src, nameGen: () => 'id');

    expect(out, '${tmp.path}/mform_attachments/id');
    expect(File(out).existsSync(), isTrue);
  });

  test('deleteAttachmentCopy removes the file and is safe when absent',
      () async {
    final src = File('${tmp.path}/a.png')..writeAsStringSync('Y');
    final out = await copyToAttachmentStore(src, nameGen: () => 'del');
    expect(File(out).existsSync(), isTrue);

    await deleteAttachmentCopy(out);
    expect(File(out).existsSync(), isFalse);

    // second delete must not throw
    await deleteAttachmentCopy(out);
  });
}
