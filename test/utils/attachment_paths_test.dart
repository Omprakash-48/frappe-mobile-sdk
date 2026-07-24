import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_paths.dart';

void main() {
  group('isLocalAttachmentPath', () {
    test('local paths are true', () {
      expect(isLocalAttachmentPath('/data/user/0/app/files/IMG.jpg'), isTrue);
      expect(isLocalAttachmentPath('/storage/emulated/0/x.pdf'), isTrue);
      expect(
        isLocalAttachmentPath('/data/user/0/com.app/mform_attachments/a.png'),
        isTrue,
      );
    });

    test('server urls are false', () {
      for (final v in [
        '/files/a.png',
        '/private/files/a.png',
        'http://h/f.png',
        'https://h/f.png',
        '/api/method/frappe.handler.download_file?file_url=%2Ffiles%2Fa.png',
      ]) {
        expect(isLocalAttachmentPath(v), isFalse, reason: v);
      }
    });

    test('pending markers are false (re-save safety)', () {
      expect(isLocalAttachmentPath('pending:5'), isFalse);
      expect(isLocalAttachmentPath('pending:12345'), isFalse);
    });

    test('null / non-string / empty are false', () {
      expect(isLocalAttachmentPath(null), isFalse);
      expect(isLocalAttachmentPath(''), isFalse);
      expect(isLocalAttachmentPath('   '), isFalse);
      expect(isLocalAttachmentPath(42), isFalse);
    });
  });

  group('parsePendingMarkerId', () {
    test('parses valid markers', () {
      expect(parsePendingMarkerId('pending:1'), 1);
      expect(parsePendingMarkerId('pending:42'), 42);
    });
    test('rejects non-markers', () {
      expect(parsePendingMarkerId('/files/a.png'), isNull);
      expect(parsePendingMarkerId('pending:abc'), isNull);
      expect(parsePendingMarkerId('pending:'), isNull);
      expect(parsePendingMarkerId(null), isNull);
      expect(parsePendingMarkerId(7), isNull);
    });
  });

  group('attachmentDisplaySource', () {
    test('resolves a pending marker to its local path', () {
      expect(
        attachmentDisplaySource('pending:1', {1: '/appdir/a.jpg'}),
        '/appdir/a.jpg',
      );
    });
    test('unknown pending id -> null (broken placeholder, value kept)', () {
      expect(attachmentDisplaySource('pending:9', {1: '/a'}), isNull);
      expect(attachmentDisplaySource('pending:1', null), isNull);
    });
    test('server urls and local paths pass through unchanged', () {
      expect(attachmentDisplaySource('/files/x.png', null), '/files/x.png');
      expect(attachmentDisplaySource('/data/local.jpg', {}), '/data/local.jpg');
      expect(
        attachmentDisplaySource('https://h/f.png', {}),
        'https://h/f.png',
      );
    });
    test('null / empty -> null', () {
      expect(attachmentDisplaySource(null, {}), isNull);
      expect(attachmentDisplaySource('', {}), isNull);
      expect(attachmentDisplaySource('   ', {}), isNull);
    });
  });
}
