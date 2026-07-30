import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/error_log_collector.dart';
import 'package:frappe_mobile_sdk/src/sync/mobile_error_record.dart';

MobileErrorRecord rec({
  String doctype = 'Household',
  String operation = 'INSERT',
  int status = 417,
  String exc = 'ValidationError',
  String user = 'u1@x',
  String uuid = 'uuid-1',
  String? message = 'Value missing for row 7',
  int at = 1000,
}) => MobileErrorRecord(
  doctype: doctype,
  operation: operation,
  httpStatus: status,
  excType: exc,
  errorUser: user,
  errorUserRoles: const ['Mobile User'],
  requestMethod: 'POST',
  requestUrl: 'https://x.test/api/resource/$doctype',
  requestPayload: '{"doctype":"$doctype","mobile_uuid":"$uuid"}',
  responseBody: '{"exc_type":"$exc"}',
  traceId: null,
  mobileUuid: uuid,
  message: message,
  occurredAtMillis: at,
);

void main() {
  test('same root cause collapses to one signature with cumulative count', () {
    final c = ErrorLogCollector();
    c.record(rec(uuid: 'a'));
    c.record(
      rec(uuid: 'b', message: 'Value missing for row 3'),
    ); // normalizes equal
    final out = c.drain();
    expect(out.length, 1);
    expect(out.first.occurrenceCount, 2);
  });

  test(
    'different user => different signature => separate rows (M2 intentional)',
    () {
      // errorUser is INTENTIONALLY part of the signature: per-user error
      // attribution is a product requirement, so the same failing endpoint hit
      // by different field workers must surface as separate rows. (Reviewer
      // suggested aggregating across users; pushed back — see computeSignature.)
      final c = ErrorLogCollector();
      c.record(rec(user: 'u1@x'));
      c.record(rec(user: 'u2@x'));
      expect(c.drain().length, 2);
    },
  );

  test(
    'different exc_type / status / doctype / operation => separate rows',
    () {
      final c = ErrorLogCollector();
      c.record(rec());
      c.record(rec(exc: 'MandatoryError'));
      c.record(rec(status: 403));
      c.record(rec(doctype: 'Member'));
      c.record(rec(operation: 'UPDATE'));
      expect(c.drain().length, 5);
    },
  );

  test('keeps only the most-recent 5 examples (rolling eviction)', () {
    final c = ErrorLogCollector();
    for (var i = 0; i < 8; i++) {
      c.record(rec(uuid: 'u$i', at: 1000 + i));
    }
    final out = c.drain();
    expect(out.length, 1);
    expect(out.first.occurrenceCount, 8);
    expect(out.first.examples.length, 5);
    // most recent 5 = u3..u7
    expect(out.first.examples.map((e) => e.mobileUuid).toList(), [
      'u3',
      'u4',
      'u5',
      'u6',
      'u7',
    ]);
  });

  test('drain clears state', () {
    final c = ErrorLogCollector();
    c.record(rec());
    expect(c.drain().length, 1);
    expect(c.drain().length, 0);
  });

  test('collapses an unterminated quoted span (truncated message)', () {
    // LOW: the quoted-string normalization is a hash tiebreaker. A truncated
    // server message can drop the closing quote; two such messages differing
    // only inside the unterminated quote should still collapse to one
    // signature.
    final s1 = computeSignature(rec(message: 'save failed for "alpha'));
    final s2 = computeSignature(rec(message: 'save failed for "beta'));
    expect(s1, s2);
  });
}
