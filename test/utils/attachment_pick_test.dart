import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_pick.dart';

void main() {
  // Fakes injected in place of the real copy/delete helpers.
  late List<String> deleted;
  Future<String> fakeCopy(File src) async => '/appdocs/mform_attachments/dur.jpg';
  Future<void> fakeDelete(String path) async => deleted.add(path);

  setUp(() => deleted = []);

  final picked = File('/cache/IMG_1.jpg');

  test('offline: stores the durable copy, never uploads', () async {
    var uploadCalled = false;
    final result = await resolvePickedAttachment(
      picked: picked,
      online: false,
      uploadFile: (f) async {
        uploadCalled = true;
        return 'https://server/files/x.jpg';
      },
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
    expect(uploadCalled, isFalse);
    expect(deleted, isEmpty);
  });

  test('online: uploads from the durable copy, returns url, deletes copy',
      () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: (f) async => '/files/uploaded.jpg',
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/files/uploaded.jpg');
    expect(deleted, ['/appdocs/mform_attachments/dur.jpg']); // copy reclaimed
  });

  test('online but upload throws: falls back to durable copy', () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: (f) async => throw const SocketException('offline mid-upload'),
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
    expect(deleted, isEmpty); // keep the copy for save-time enqueue
  });

  test('online but upload returns empty: falls back to durable copy', () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: (f) async => '',
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
  });

  test('no uploader (uploadFile null): stores durable copy', () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: null,
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
  });
}
