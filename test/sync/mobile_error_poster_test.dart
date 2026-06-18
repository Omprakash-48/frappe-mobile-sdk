import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/error_log_collector.dart';
import 'package:frappe_mobile_sdk/src/sync/mobile_error_poster.dart';

AggregatedError agg(String sig) => AggregatedError(
  signature: sig,
  doctype: 'Household',
  operation: 'INSERT',
  httpStatus: 417,
  excType: 'ValidationError',
  errorUser: 'u@x',
  errorUserRoles: const ['Mobile User'],
  requestMethod: 'POST',
  requestUrl: 'https://x.test/api/resource/Household',
  traceId: null,
  occurrenceCount: 1,
  lastSeenMillis: 1000,
  examples: const [],
);

void main() {
  test('posts one call per aggregated signature', () async {
    final calls = <Map<String, dynamic>?>[];
    final poster = MobileErrorPoster(
      call: (method, args) async {
        calls.add(args);
        return {'status': 'ok'};
      },
    );
    await poster.flush([agg('s1'), agg('s2')]);
    expect(calls.length, 2);
    // The aggregated record is wrapped under `payload` to match the server's
    // `report_error(payload)` signature.
    final payload = calls.first!['payload'] as Map<String, dynamic>;
    expect(payload['signature'], 's1');
  });

  test('a failing call never throws (best-effort drop)', () async {
    final poster = MobileErrorPoster(
      call: (method, args) async => throw StateError('network down'),
    );
    // Must complete without throwing.
    await poster.flush([agg('s1'), agg('s2')]);
  });

  test('empty list is a no-op', () async {
    var called = false;
    final poster = MobileErrorPoster(
      call: (m, a) async {
        called = true;
        return null;
      },
    );
    await poster.flush([]);
    expect(called, isFalse);
  });
}
