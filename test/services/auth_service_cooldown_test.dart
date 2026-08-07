import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:frappe_mobile_sdk/src/services/session_health.dart';

void main() {
  group('session health', () {
    test('a fresh AuthService reports healthy', () {
      expect(AuthService().sessionHealth.value, SessionHealth.healthy);
    });

    test('markSessionRecovered clears an expired session', () {
      final auth = AuthService();
      auth.debugMarkExpired('fa1@example.com');
      expect(auth.sessionHealth.value, SessionHealth.expired);
      expect(auth.expiredSessionEmail, 'fa1@example.com');

      auth.markSessionRecovered();
      expect(auth.sessionHealth.value, SessionHealth.healthy);
      expect(auth.expiredSessionEmail, isNull);
    });
  });

  group('refresh circuit breaker', () {
    test('a dead session never attempts another refresh', () {
      final auth = AuthService();
      auth.debugMarkExpired('fa1@example.com');
      expect(auth.debugRefreshAllowed(), isFalse);
    });

    test('a transient failure blocks retries until the cooldown elapses', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      auth.debugRecordTransientFailure(rateLimited: false); // 30s
      expect(auth.debugRefreshAllowed(), isFalse);
      expect(auth.sessionHealth.value, SessionHealth.degraded);

      now = now.add(const Duration(seconds: 29));
      expect(auth.debugRefreshAllowed(), isFalse);

      now = now.add(const Duration(seconds: 2));
      expect(auth.debugRefreshAllowed(), isTrue);
    });

    test('backoff escalates 30s -> 2m -> 5m -> 15m and then holds', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;
      const expected = [
        Duration(seconds: 30),
        Duration(minutes: 2),
        Duration(minutes: 5),
        Duration(minutes: 15),
        Duration(minutes: 15),
      ];
      for (final d in expected) {
        auth.debugRecordTransientFailure(rateLimited: false);
        now = now.add(d - const Duration(seconds: 1));
        expect(auth.debugRefreshAllowed(), isFalse, reason: 'still within $d');
        now = now.add(const Duration(seconds: 2));
        expect(auth.debugRefreshAllowed(), isTrue, reason: 'past $d');
      }
    });

    test('a 429 jumps straight to the maximum cooldown — the limiter is '
        'per-user, so retrying sooner only extends the lockout', () {
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      final auth = AuthService()..clock = () => now;

      auth.debugRecordTransientFailure(rateLimited: true);
      now = now.add(const Duration(minutes: 14));
      expect(auth.debugRefreshAllowed(), isFalse);
      now = now.add(const Duration(minutes: 2));
      expect(auth.debugRefreshAllowed(), isTrue);
    });

    test('recovery re-arms the refresh path', () {
      final auth = AuthService()..clock = () => DateTime(2026, 8, 7, 12);
      auth.debugRecordTransientFailure(rateLimited: true);
      expect(auth.debugRefreshAllowed(), isFalse);
      auth.markSessionRecovered();
      expect(auth.debugRefreshAllowed(), isTrue);
      expect(auth.sessionHealth.value, SessionHealth.healthy);
    });
  });
}
