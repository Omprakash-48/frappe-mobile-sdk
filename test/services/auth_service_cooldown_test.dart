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
}
