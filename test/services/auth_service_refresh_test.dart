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

    test('a 401/403 carried by ApiException is still definitive', () {
      // RestHelper only builds an AuthException when the error body parses as
      // JSON. A non-JSON body — Frappe behind nginx, a proxy error page, an
      // HTML login redirect — returns early as ApiException(msg, 401). Matching
      // on the subtype missed exactly those, so the dead refresh token was KEPT
      // and the client 401'd -> refreshed -> failed forever with no route to
      // re-login.
      expect(
        isDefinitiveAuthRejection(
          ApiException(
            '<html><body>401 Authorization Required</body></html>',
            401,
          ),
        ),
        isTrue,
      );
      expect(
        isDefinitiveAuthRejection(ApiException('<h1>403 Forbidden</h1>', 403)),
        isTrue,
      );
    });

    test('a FrappeException base instance is classified by status too', () {
      expect(isDefinitiveAuthRejection(FrappeException('nope', 401)), isTrue);
      expect(isDefinitiveAuthRejection(FrappeException('nope', 500)), isFalse);
      expect(isDefinitiveAuthRejection(FrappeException('no status')), isFalse);
    });

    test('a NetworkException carrying a status is NOT treated as transport-'
        'only — status wins', () {
      // Defensive: no SDK site constructs one this way today (all six pass no
      // status), but if one ever did, a 401 means the credential was rejected.
      expect(
        isDefinitiveAuthRejection(NetworkException('gateway said no', 401)),
        isTrue,
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
