// #42 (A3): equal-jitter exponential backoff for HTTP retries.
// Verifies the delay stays within the equal-jitter window [base/2, base],
// is randomised (de-synchronises simultaneous client reconnects), is
// deterministic under a seeded RNG, and is overflow-safe for large attempts.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

void main() {
  group('retryBackoffDelay (#42 equal-jitter)', () {
    test('delay falls within [base/2, base] for attempts 1..6', () {
      final rnd = Random(1);
      for (var attempt = 1; attempt <= 6; attempt++) {
        final base = 500 * (1 << attempt);
        final d = retryBackoffDelay(attempt, random: rnd).inMilliseconds;
        expect(
          d,
          inInclusiveRange(base ~/ 2, base),
          reason: 'attempt $attempt should be within equal-jitter window',
        );
      }
    });

    test(
      'is randomised — successive draws for the same attempt can differ',
      () {
        final rnd = Random(42);
        final samples = <int>{
          for (var i = 0; i < 20; i++)
            retryBackoffDelay(3, random: rnd).inMilliseconds,
        };
        expect(
          samples.length,
          greaterThan(1),
          reason: 'jitter must vary, not be deterministic per attempt',
        );
      },
    );

    test('is deterministic under a seeded RNG (reproducible)', () {
      final a = retryBackoffDelay(4, random: Random(7)).inMilliseconds;
      final b = retryBackoffDelay(4, random: Random(7)).inMilliseconds;
      expect(a, b);
    });

    test('clamps huge attempts — never overflows to a tiny/negative delay', () {
      final d = retryBackoffDelay(60, random: Random(1)).inMilliseconds;
      expect(d, greaterThan(0));
      // attempt clamped to 16 → base = 500 * 2^16
      final cappedBase = 500 * (1 << 16);
      expect(d, inInclusiveRange(cappedBase ~/ 2, cappedBase));
    });

    test('attempt 0 still yields a sane positive delay', () {
      final d = retryBackoffDelay(0, random: Random(1)).inMilliseconds;
      expect(d, inInclusiveRange(250, 500)); // base=500 → [250,500]
    });

    test('maxDelayMs caps the delay window (BW4)', () {
      // Without a cap, attempt 16 → base ~9.1h. With a 30s cap the delay must
      // stay in the capped equal-jitter window [maxDelayMs/2, maxDelayMs].
      const cap = 30000;
      for (final attempt in [16, 60]) {
        final d = retryBackoffDelay(
          attempt,
          random: Random(1),
          maxDelayMs: cap,
        ).inMilliseconds;
        expect(
          d,
          inInclusiveRange(cap ~/ 2, cap),
          reason: 'attempt $attempt with cap must stay within [cap/2, cap]',
        );
      }
    });

    test('maxDelayMs does not inflate already-small delays', () {
      // A cap far above the natural base must leave the delay untouched.
      final d = retryBackoffDelay(
        1,
        random: Random(1),
        maxDelayMs: 30000,
      ).inMilliseconds;
      expect(d, inInclusiveRange(500, 1000)); // base=1000 → [500,1000]
    });
  });
}
