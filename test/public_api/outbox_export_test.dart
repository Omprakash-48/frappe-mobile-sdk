// #53 (A5): OutboxRow/OutboxState/OutboxOperation/ErrorCode must be reachable
// from the PUBLIC barrel so app teams build type-safe outbox UI without
// `implementation_imports`. This is a compile-time export contract: if the
// barrel stops exporting them, this file fails to compile.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  test('outbox types are exported on the public surface', () {
    final row = OutboxRow(
      id: 1,
      doctype: 'X',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
      state: OutboxState.paused,
      retryCount: 0,
      errorCode: ErrorCode.VALIDATION,
      createdAt: DateTime.utc(2026),
    );
    expect(row.state, OutboxState.paused);
    expect(row.isTerminal, isTrue);
    expect(ErrorCode.NETWORK.isTerminal, isFalse);
  });
}
