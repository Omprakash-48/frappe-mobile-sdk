import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

void main() {
  group('isDefinitiveAuthRejection', () {
    test('HTTP 401/403 are definitive rejections (token must be cleared)', () {
      expect(
        isDefinitiveAuthRejection(AuthException('unauthorized', 401)),
        isTrue,
      );
      expect(
        isDefinitiveAuthRejection(AuthException('forbidden', 403)),
        isTrue,
      );
    });

    test('transport failures are NOT rejections — token is kept so an offline '
        'user stays signed in on cached credentials', () {
      expect(
        isDefinitiveAuthRejection(NetworkException('No internet connection')),
        isFalse,
      );
      expect(
        isDefinitiveAuthRejection(
          NetworkException('Server is not responding. Check your connection.'),
        ),
        isFalse,
      );
    });

    test('validation (417) and non-auth statuses never wipe the token', () {
      expect(
        isDefinitiveAuthRejection(ValidationException('bad payload')),
        isFalse,
      );
      expect(
        isDefinitiveAuthRejection(AuthException('server error', 500)),
        isFalse,
      );
      expect(
        isDefinitiveAuthRejection(ApiException('not found', 404)),
        isFalse,
      );
      expect(isDefinitiveAuthRejection(Exception('unexpected')), isFalse);
    });
  });
}
