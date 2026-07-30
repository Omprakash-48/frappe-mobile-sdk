import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/sync/error_log_collector.dart';
import 'package:frappe_mobile_sdk/src/services/error_capture.dart';

void main() {
  ValidationException stamped(int status) =>
      ValidationException('bad', {'exc_type': 'ValidationError'})
        ..requestUrl = 'https://x.test/api/resource/Household'
        ..requestMethod = 'POST'
        ..requestBody = {'doctype': 'Household', 'mobile_uuid': 'u1'}
        ..responseBodyRaw = '{"exc_type":"ValidationError"}'
        ..traceId = 't1';

  test('records a terminal 4Xx into the collector', () {
    final c = ErrorLogCollector();
    recordTerminalFailure(
      collector: c,
      method: 'POST',
      payload: {'doctype': 'Household', 'mobile_uuid': 'u1'},
      error: stamped(417),
      sessionUserName: 'u1@x',
      sessionUserRoles: const ['Mobile User'],
      nowMillis: 5,
    );
    final out = c.drain();
    expect(out.length, 1);
    expect(out.first.doctype, 'Household');
    expect(out.first.operation, 'INSERT');
    expect(out.first.httpStatus, 417);
    expect(out.first.excType, 'ValidationError');
    expect(out.first.errorUser, 'u1@x');
  });

  test('does NOT record a NetworkException (transient, out of scope)', () {
    final c = ErrorLogCollector();
    recordTerminalFailure(
      collector: c,
      method: 'POST',
      payload: const {'doctype': 'Household'},
      error: NetworkException('offline'),
      sessionUserName: 'u1@x',
      sessionUserRoles: const [],
      nowMillis: 5,
    );
    expect(c.drain(), isEmpty);
  });

  test('does NOT record when statusCode is null', () {
    final c = ErrorLogCollector();
    recordTerminalFailure(
      collector: c,
      method: 'POST',
      payload: const {'doctype': 'Household'},
      error: ApiException('weird'), // no statusCode
      sessionUserName: 'u@x',
      sessionUserRoles: const [],
      nowMillis: 5,
    );
    expect(c.drain(), isEmpty);
  });

  test('coerces a non-String mobile_uuid instead of dropping the log', () {
    // Capture runs inside the push catch block before the original
    // FrappeException is rethrown. A non-String mobile_uuid/doctype must not
    // throw (recordTerminalFailureSafe would swallow it and lose the whole
    // log); it is coerced via toString() so the log still survives.
    final c = ErrorLogCollector();
    expect(
      () => recordTerminalFailureSafe(
        collector: c,
        method: 'POST',
        payload: const {'doctype': 'Household', 'mobile_uuid': 123},
        error: stamped(417),
        sessionUserName: 'u1@x',
        sessionUserRoles: const ['Mobile User'],
        nowMillis: 5,
      ),
      returnsNormally,
    );
    final out = c.drain();
    expect(out.length, 1);
    expect(out.first.examples.single.mobileUuid, '123');
  });
}
