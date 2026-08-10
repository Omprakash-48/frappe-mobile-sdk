// Exercises the REAL AuthService methods end-to-end (login/persist, the
// aged-token refresh path inside restoreSession, and single-flight), rather
// than just the debug seams covered in auth_service_cooldown_test.dart.
//
// `restoreSession` is the only PUBLIC entry point that reaches the private
// `_tryRefreshMobileAuthToken` / `_doRefreshMobileAuthToken` chain without an
// `onTokenExpired` 401 round trip: when the stored token is older than the
// mirrored 24h TTL (minus a 5-minute skew), `restoreSession(isOnline: true)`
// calls the same refresh path a real 401 would. Tests below age the token to
// land on that path deliberately.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:frappe_mobile_sdk/src/services/session_health.dart';

/// `AuthService.getBaseUrl`/`restoreSession` read `FlutterSecureStorage`,
/// which has no platform implementation under `flutter test`. Stubbing its
/// method channel directly is the only way to reach those code paths from a
/// unit test without a real device.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage({String? baseUrl}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
    switch (call.method) {
      case 'read':
        final key = (call.arguments as Map)['key'] as String;
        return key == 'frappe_base_url' ? baseUrl : null;
      case 'readAll':
        return <String, String>{};
      case 'containsKey':
        return false;
      default:
        return null;
    }
  });
}

/// A token old enough to cross the mirrored 24h-minus-5m-skew threshold in
/// `restoreSession`, so it takes the refresh branch instead of the cached-
/// bearer fast path.
int _agedCreatedAt() =>
    DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
  });
  tearDown(() async => db.close());

  group('(a) fresh credential clears the dead-session latch', () {
    test(
      'persistExternalLoginResponse after debugMarkExpired leaves refresh '
      're-armed and session healthy',
      () async {
        final auth = AuthService.forTesting(FrappeClient('http://x'), database: db);

        auth.debugMarkExpired('dead@example.com');
        expect(auth.debugRefreshAllowed(), isFalse);
        expect(auth.sessionHealth.value, SessionHealth.expired);

        await auth.persistExternalLoginResponse({
          'access_token': 'AT-fresh',
          'refresh_token': 'RT-fresh',
          'user': 'alive@example.com',
        });

        expect(
          auth.debugRefreshAllowed(),
          isTrue,
          reason: 'a fresh login must retire the latch, or the refresh path '
              'stays permanently gated post re-login',
        );
        expect(auth.sessionHealth.value, SessionHealth.healthy);
        expect(auth.expiredSessionEmail, isNull);
      },
    );
  });

  group('(b) successful refresh recovers session health', () {
    test('restoreSession refresh success calls markSessionRecovered', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/method/mobile_auth.refresh_token');
          return http.Response(
            jsonEncode({'access_token': 'AT-new', 'refresh_token': 'RT-new'}),
            200,
          );
        }),
      );
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: 'RT-old',
          user: 'user@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      _mockSecureStorage(baseUrl: 'http://x');
      final auth = AuthService.forTesting(client, database: db);

      // Start from a real degraded state (not the trivial default-healthy
      // case) so a pass here proves markSessionRecovered ran.
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      auth.clock = () => now;
      auth.debugRecordTransientFailure(rateLimited: false);
      expect(auth.sessionHealth.value, SessionHealth.degraded);
      now = now.add(const Duration(seconds: 31)); // past the 30s cooldown

      final restored = await auth.restoreSession(isOnline: true);

      expect(restored, isTrue);
      expect(auth.sessionHealth.value, SessionHealth.healthy);
      expect(auth.debugRefreshAllowed(), isTrue);
    });
  });

  group('(c) definitive rejection (417) captures email before deleting the token', () {
    test('expiredSessionEmail is populated and the token row is gone', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({'message': 'Invalid or expired refresh token'}),
            417,
          );
        }),
      );
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: 'RT-dead',
          user: 'dead@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      _mockSecureStorage(baseUrl: 'http://x');
      final auth = AuthService.forTesting(client, database: db);

      await auth.restoreSession(isOnline: true);

      expect(auth.expiredSessionEmail, 'dead@example.com');
      expect(auth.sessionHealth.value, SessionHealth.expired);
      expect(auth.debugRefreshAllowed(), isFalse);
      expect(await db.authTokenDao.getCurrentToken(), isNull);
    });
  });

  group('(d) non-definitive failure (429) keeps the token row', () {
    test('token survives a rate-limit lockout', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(jsonEncode({'message': 'slow down'}), 429);
        }),
      );
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: 'RT-old',
          user: 'user@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      _mockSecureStorage(baseUrl: 'http://x');
      final auth = AuthService.forTesting(client, database: db);

      final restored = await auth.restoreSession(isOnline: true);

      // The row survives, so restoreSession installs it as the best
      // available credential rather than forcing a re-login.
      expect(restored, isTrue);
      expect(auth.expiredSessionEmail, isNull);
      expect(auth.sessionHealth.value, SessionHealth.degraded);
      expect(auth.debugRefreshAllowed(), isFalse);
      final surviving = await db.authTokenDao.getCurrentToken();
      expect(surviving, isNotNull);
      expect(surviving!.refreshToken, 'RT-old');
    });
  });

  group('(e) single-flight refresh', () {
    test('concurrent restoreSession calls share ONE in-flight refresh', () async {
      var refreshCalls = 0;
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          if (req.url.path == '/api/method/mobile_auth.refresh_token') {
            refreshCalls++;
            // Hold the response open long enough that both callers are
            // provably overlapping when the second one arrives.
            await Future.delayed(const Duration(milliseconds: 50));
            return http.Response(
              jsonEncode({
                'access_token': 'AT-new',
                'refresh_token': 'RT-new',
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: 'RT-old',
          user: 'user@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      _mockSecureStorage(baseUrl: 'http://x');
      final auth = AuthService.forTesting(client, database: db);

      final results = await Future.wait([
        auth.restoreSession(isOnline: true),
        auth.restoreSession(isOnline: true),
      ]);

      expect(
        refreshCalls,
        1,
        reason: 'two overlapping callers must share one refresh, or each '
            '401 wave fires a competing refresh against the backend',
      );
      expect(results, everyElement(isTrue));
    });
  });
}
