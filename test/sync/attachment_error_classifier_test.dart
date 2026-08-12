import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_error_classifier.dart';

void main() {
  group('terminal — retrying can never succeed', () {
    test('ValidationException (HTTP 417) is terminal', () {
      // Frappe's `frappe.throw` yields 417; this is how an oversized file
      // (MaxFileSizeReachedError) actually reaches the client.
      expect(
        isTerminalAttachmentError(
          ValidationException('File size exceeded the maximum allowed size'),
        ),
        isTrue,
      );
    });

    test('AuthException 403 (permission denied) is terminal', () {
      expect(
        isTerminalAttachmentError(AuthException('not permitted', 403)),
        isTrue,
      );
    });

    test('a 4xx ApiException is terminal', () {
      expect(
        isTerminalAttachmentError(ApiException('bad request', 400)),
        isTrue,
      );
      expect(isTerminalAttachmentError(ApiException('not found', 404)), isTrue);
    });

    test('MaxFileSizeReachedError is terminal however it is wrapped', () {
      expect(
        isTerminalAttachmentError(
          Exception('frappe.exceptions.MaxFileSizeReachedError: too big'),
        ),
        isTrue,
      );
    });
  });

  group('transient — a later attempt may succeed', () {
    test('NetworkException is transient', () {
      expect(
        isTerminalAttachmentError(NetworkException('Upload failed: socket')),
        isFalse,
      );
    });

    test('AuthException 401 is transient — a token refresh fixes it', () {
      // 401 means the credential expired, not that this file is unacceptable.
      // Rejecting here would strand the attachment behind a re-login.
      expect(isTerminalAttachmentError(AuthException('expired', 401)), isFalse);
    });

    test('5xx is transient', () {
      expect(isTerminalAttachmentError(ApiException('boom', 500)), isFalse);
      expect(
        isTerminalAttachmentError(ApiException('unavailable', 503)),
        isFalse,
      );
    });

    test('429 and 408 are transient despite being 4xx', () {
      expect(
        isTerminalAttachmentError(ApiException('slow down', 429)),
        isFalse,
      );
      expect(isTerminalAttachmentError(ApiException('timeout', 408)), isFalse);
    });

    test('an unrecognised error defaults to transient', () {
      // Fail toward retrying: a wrongly-transient error costs one retry, but a
      // wrongly-terminal one strands the user's file with no auto-recovery.
      expect(
        isTerminalAttachmentError(Exception('something unexpected')),
        isFalse,
      );
    });

    test('an ApiException with no status is transient', () {
      expect(isTerminalAttachmentError(ApiException('no status')), isFalse);
    });
  });
}
