// #53 (A5): terminal-error classification + `paused` outbox state.
// A server validate() rejection (HTTP 417 → VALIDATION) must be classified
// terminal so the engine pauses the row instead of retrying forever.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';

void main() {
  group('ErrorCode.isTerminal (#53)', () {
    test(
      'user/permission errors are terminal (no auto-retry can fix them)',
      () {
        expect(ErrorCode.VALIDATION.isTerminal, isTrue);
        expect(ErrorCode.MANDATORY.isTerminal, isTrue);
        expect(ErrorCode.PERMISSION_DENIED.isTerminal, isTrue);
        expect(ErrorCode.LINK_EXISTS.isTerminal, isTrue);
      },
    );

    test('transient/system errors are NOT terminal (retryable)', () {
      expect(ErrorCode.NETWORK.isTerminal, isFalse);
      expect(ErrorCode.TIMEOUT.isTerminal, isFalse);
      expect(ErrorCode.TIMESTAMP_MISMATCH.isTerminal, isFalse);
      expect(ErrorCode.UNKNOWN.isTerminal, isFalse);
    });
  });

  group('OutboxRow.isTerminal (#53)', () {
    OutboxRow row({ErrorCode? code, OutboxState state = OutboxState.failed}) =>
        OutboxRow(
          id: 1,
          doctype: 'X',
          mobileUuid: 'u1',
          operation: OutboxOperation.insert,
          state: state,
          retryCount: 0,
          errorCode: code,
          createdAt: DateTime.utc(2026),
        );

    test('derives from errorCode', () {
      expect(row(code: ErrorCode.VALIDATION).isTerminal, isTrue);
      expect(row(code: ErrorCode.NETWORK).isTerminal, isFalse);
    });

    test('null errorCode is not terminal (non-paused)', () {
      expect(row(code: null).isTerminal, isFalse);
    });

    test(
      'paused row is terminal regardless of errorCode (H6 — no stray Retry)',
      () {
        // The engine parks paused rows out of the drain queue; isTerminal must
        // report true so a consumer UI gating Retry on it never offers a retry
        // the engine refuses — even on the edge of a null errorCode.
        expect(row(state: OutboxState.paused, code: null).isTerminal, isTrue);
        expect(
          row(state: OutboxState.paused, code: ErrorCode.NETWORK).isTerminal,
          isTrue,
        );
      },
    );
  });

  group('OutboxState.paused (#53)', () {
    test('paused is a distinct state', () {
      expect(OutboxState.values, contains(OutboxState.paused));
    });

    test('paused wireName round-trips', () {
      expect(OutboxState.paused.wireName, 'paused');
      expect(OutboxStateHelpers.parse('paused'), OutboxState.paused);
    });
  });
}
