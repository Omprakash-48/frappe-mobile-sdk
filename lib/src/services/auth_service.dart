import 'dart:developer' as dev;

import '../api/client.dart';
import '../api/exceptions.dart';
import '../api/oauth2_helper.dart';
import '../database/app_database.dart';
import '../database/entities/auth_token_entity.dart';
import '../database/entities/doctype_meta_entity.dart';
import '../models/mobile_form_name.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'session_health.dart';

/// Handles Frappe authentication via credentials, API key, or OAuth 2.0.
///
/// Tokens are stored in secure storage. OAuth tokens are automatically
/// refreshed on 401 when [onTokenExpired] is configured.
class AuthService {
  static const String _keyBaseUrl = 'frappe_base_url';
  static const String _keyApiKey = 'frappe_api_key';
  static const String _keyApiSecret = 'frappe_api_secret';
  static const String _keyOAuthAccessToken = 'frappe_oauth_access_token';
  static const String _keyOAuthRefreshToken = 'frappe_oauth_refresh_token';
  static const String _keyOAuthExpiresAt = 'frappe_oauth_expires_at';
  static const String _keyOAuthClientId = 'frappe_oauth_client_id';
  static const String _keyOAuthClientSecret = 'frappe_oauth_client_secret';
  static const String _keyMobileUuid = 'frappe_mobile_uuid';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );
  static const Uuid _uuid = Uuid();
  FrappeClient? _client;
  bool _isAuthenticated = false;

  /// Maps Frappe's `roles` JSON list (returned by `/api/method/login`,
  /// `verify_login_otp`, and the post-login `frappe.auth.get_logged_user`
  /// response) into a clean `List<String>`. Drops null and empty entries,
  /// returns an empty list when the input is null. Shared by [login],
  /// [verifyLoginOtp], and [fetchUserInfo] so role-extraction stays uniform
  /// across auth paths.
  static List<String> _parseRoles(dynamic rolesJson) {
    if (rolesJson is! List) return <String>[];
    return rolesJson
        .map((r) => r.toString())
        .where((r) => r.isNotEmpty)
        .toList();
  }

  /// In-flight refresh, shared so concurrent 401s (e.g. the parallel closure
  /// meta fetches) await the SAME refresh instead of each starting their own
  /// or bailing out.
  Future<bool>? _refreshInFlight;

  /// Published liveness of the stored credential. Never wipes anything on its
  /// own — hosts decide what to show. See [SessionHealth].
  final ValueNotifier<SessionHealth> sessionHealth =
      ValueNotifier<SessionHealth>(SessionHealth.healthy);

  String? _expiredSessionEmail;

  /// Email of the user whose session expired. Captured BEFORE the token row is
  /// deleted, because the row is the only place that email lives in the SDK.
  String? get expiredSessionEmail => _expiredSessionEmail;

  /// Clears the dead-session latch after a successful re-login, re-arming the
  /// refresh path. Idempotent.
  void markSessionRecovered() {
    _sessionDead = false;
    _refreshCooldownUntil = null;
    _consecutiveRefreshFailures = 0;
    _expiredSessionEmail = null;
    sessionHealth.value = SessionHealth.healthy;
  }

  /// Test seam — drives the latch without a network round trip.
  @visibleForTesting
  void debugMarkExpired(String? email) {
    _sessionDead = true;
    _expiredSessionEmail = email;
    sessionHealth.value = SessionHealth.expired;
  }

  bool _sessionDead = false;
  DateTime? _refreshCooldownUntil;
  int _consecutiveRefreshFailures = 0;

  /// Refresh backoff ladder. Indexed by consecutive failure count; the last
  /// entry repeats. Deliberately coarse — a refresh that just failed is very
  /// unlikely to succeed seconds later, and each attempt costs rate-limit
  /// budget the user cannot get back.
  static const List<Duration> _refreshBackoff = <Duration>[
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 15),
  ];

  /// Injectable clock so cooldown tests do not sleep.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// True when a refresh may be attempted right now.
  @visibleForTesting
  bool debugRefreshAllowed() {
    if (_sessionDead) return false;
    final until = _refreshCooldownUntil;
    return until == null || !clock().isBefore(until);
  }

  /// Records a non-definitive failure and arms the next cooldown.
  @visibleForTesting
  void debugRecordTransientFailure({required bool rateLimited}) {
    final index = rateLimited
        ? _refreshBackoff.length - 1
        : _consecutiveRefreshFailures.clamp(0, _refreshBackoff.length - 1);
    _consecutiveRefreshFailures++;
    _refreshCooldownUntil = clock().add(_refreshBackoff[index]);
    sessionHealth.value = SessionHealth.degraded;
  }

  /// Mirrors mobile-control's ACCESS_TOKEN_TTL_SECONDS (24h). Used ONLY to
  /// proactively refresh an aged Bearer on restore; the reactive 401->refresh
  /// path is the safety net for any backend whose TTL differs, so this is an
  /// optimization, not a hard assumption.
  static const Duration _mobileAccessTokenTtl = Duration(hours: 24);
  static const Duration _tokenRefreshSkew = Duration(minutes: 5);
  AppDatabase? _database;
  List<String> _roles = [];
  String? _language;

  /// Cached user info from the last successful authentication.
  ({String email, String fullName})? _cachedUserInfo;

  /// Returns the current user's email and full name, or null if not authenticated.
  ({String email, String fullName})? get currentUserInfo => _cachedUserInfo;

  /// Default constructor. Call [initialize] before using auth methods.
  AuthService();

  /// Named constructor used by [FrappeSDK.forTesting]: wires [client] and
  /// [database] directly without touching [FlutterSecureStorage] (which is
  /// unavailable in unit/widget tests).
  AuthService.forTesting(FrappeClient client, {AppDatabase? database}) {
    _client = client;
    _database = database;
  }

  /// Initializes the client with the given [baseUrl].
  ///
  /// Optionally provide [database] for stateless login token storage.
  void initialize(String baseUrl, {AppDatabase? database}) {
    _client = FrappeClient(baseUrl, onTokenExpired: _tryRefreshMobileAuthToken);
    _database = database;
    _storage.write(key: _keyBaseUrl, value: baseUrl);
  }

  /// Returns the stored base URL, or null if not set.
  Future<String?> getBaseUrl() async {
    return _storage.read(key: _keyBaseUrl);
  }

  /// Returns a stable UUID for this device/install. Creates and stores one if missing.
  /// Use when creating documents from mobile so server can store mobile_uuid.
  Future<String> getOrCreateMobileUuid() async {
    var value = await _storage.read(key: _keyMobileUuid);
    if (value == null || value.isEmpty) {
      value = _uuid.v4();
      await _storage.write(key: _keyMobileUuid, value: value);
    }
    return value;
  }

  /// The Frappe API client. Null until [initialize] is called.
  FrappeClient? get client => _client;

  /// True if authenticated and client is initialized.
  bool get isAuthenticated => _isAuthenticated && _client != null;

  /// Roles for the currently authenticated user (if provided by backend).
  List<String> get roles => List.unmodifiable(_roles);

  /// User language from login/OTP/me response (e.g. "en"). Null until set.
  String? get language => _language;

  /// Authenticates with username and password using mobile_auth.login (stateless).
  ///
  /// This is the default login method. Stores access_token and refresh_token in database.
  /// Returns user info including mobile_form_names.
  /// Throws if not initialized, database not set, or credentials are invalid.
  Future<Map<String, dynamic>> login(String username, String password) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    if (_database == null) {
      throw Exception(
        'Database not set. Call initialize(baseUrl, database: db) first.',
      );
    }

    try {
      final result = await _client!.rest.call(
        'mobile_auth.login',
        args: {'username': username, 'password': password},
      );

      final response = result is Map<String, dynamic>
          ? result
          : <String, dynamic>{};

      final accessToken = response['access_token'] as String?;
      final refreshToken = response['refresh_token'] as String?;
      final user = response['user'] as String?;
      final fullName = response['full_name'] as String?;
      final mobileFormNamesJson =
          response['mobile_form_names'] as List<dynamic>?;

      _roles = _parseRoles(response['roles']);

      _language = response['language'] as String?;

      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('Login response missing access_token');
      }
      if (refreshToken == null || refreshToken.isEmpty) {
        throw Exception('Login response missing refresh_token');
      }
      if (user == null || user.isEmpty) {
        throw Exception('Login response missing user');
      }
      dev.log('access_token: $accessToken', name: 'Auth');

      await _processLoginResponse(
        response,
        accessToken,
        refreshToken,
        user,
        fullName,
        mobileFormNamesJson,
      );
      return response;
    } catch (e) {
      _isAuthenticated = false;
      if (e is Exception) rethrow;
      throw Exception('Login failed: $e');
    }
  }

  /// Persist a login response obtained OUTSIDE the SDK (e.g. a custom SSO /
  /// `mobile_login` endpoint) into the SDK session exactly like [login] does
  /// after its own network call: writes the token to the SQLite `auth_tokens`
  /// table, sets the bearer, records `mobile_form_names`, and marks the client
  /// authenticated. This lets [restoreSession] rehydrate the session on the
  /// next cold start with no forced re-login.
  ///
  /// Tolerates a missing `refresh_token` (custom endpoints may omit it).
  Future<void> persistExternalLoginResponse(
    Map<String, dynamic> response,
  ) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    if (_database == null) {
      throw Exception(
        'Database not set. Call initialize(baseUrl, database: db) first.',
      );
    }
    final accessToken = response['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('External login response missing access_token');
    }
    final user = response['user'] as String?;
    if (user == null || user.isEmpty) {
      throw Exception('External login response missing user');
    }
    final refreshToken = (response['refresh_token'] as String?) ?? '';
    final fullName = response['full_name'] as String?;
    final mobileFormNamesJson = response['mobile_form_names'] as List<dynamic>?;
    _roles = _parseRoles(response['roles']);
    _language = response['language'] as String?;
    await _processLoginResponse(
      response,
      accessToken,
      refreshToken,
      user,
      fullName,
      mobileFormNamesJson,
    );
  }

  /// Sends OTP to mobile number for login. Returns response containing tmp_id.
  /// Call [verifyLoginOtp] with tmp_id and user-entered OTP to complete login.
  Future<Map<String, dynamic>> sendLoginOtp(String mobileNo) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    final result = await _client!.rest.call(
      'mobile_auth.send_login_otp',
      args: {'mobile_no': mobileNo},
    );
    final response = result is Map<String, dynamic>
        ? result
        : <String, dynamic>{};
    return response;
  }

  /// Verifies OTP and completes login. Returns same shape as [login].
  /// [tmpId] from [sendLoginOtp] response; [otp] is user-entered code.
  Future<Map<String, dynamic>> verifyLoginOtp(String tmpId, String otp) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    if (_database == null) {
      throw Exception(
        'Database not set. Call initialize(baseUrl, database: db) first.',
      );
    }
    try {
      final result = await _client!.rest.call(
        'mobile_auth.verify_login_otp',
        args: {'tmp_id': tmpId, 'otp': otp},
      );
      final response = result is Map<String, dynamic>
          ? result
          : <String, dynamic>{};

      final accessToken = response['access_token'] as String?;
      final refreshToken = response['refresh_token'] as String?;
      final user = response['user'] as String?;
      final fullName = response['full_name'] as String?;
      final mobileFormNamesJson =
          response['mobile_form_names'] as List<dynamic>?;

      if (accessToken == null || accessToken.isEmpty) {
        throw Exception('Verify OTP response missing access_token');
      }
      if (refreshToken == null || refreshToken.isEmpty) {
        throw Exception('Verify OTP response missing refresh_token');
      }
      if (user == null || user.isEmpty) {
        throw Exception('Verify OTP response missing user');
      }
      dev.log('access_token: $accessToken', name: 'Auth');

      _roles = _parseRoles(response['roles']);
      _language = response['language'] as String?;

      await _processLoginResponse(
        response,
        accessToken,
        refreshToken,
        user,
        fullName,
        mobileFormNamesJson,
      );
      return response;
    } catch (e) {
      _isAuthenticated = false;
      if (e is Exception) rethrow;
      throw Exception('Verify OTP failed: $e');
    }
  }

  /// Fetches current user info (roles, permissions, language, mobile_form_names).
  /// Call after OAuth or API key login to get the same shape as login response.
  /// Backend must expose e.g. mobile_auth.me returning that payload.
  Future<Map<String, dynamic>?> fetchUserInfo() async {
    if (_client == null || !_isAuthenticated) return null;
    try {
      final result = await _client!.rest.get('/api/v2/method/mobile_auth.me');
      if (result is! Map<String, dynamic>) return null;
      // /api/v2/method/* wraps the return in {"data": ...}; fall back to
      // the bare result for /api/method/* or no-envelope responses.
      final message = (result['data'] is Map<String, dynamic>)
          ? result['data'] as Map<String, dynamic>
          : result;

      _roles = _parseRoles(message['roles']);
      _language = message['language'] as String?;
      return message;
    } catch (e, st) {
      dev.log('fetchUserInfo failed — $e\n$st', name: 'Auth');
      return null;
    }
  }

  Future<void> _processLoginResponse(
    Map<String, dynamic> response,
    String accessToken,
    String refreshToken,
    String user,
    String? fullName,
    List<dynamic>? mobileFormNamesJson,
  ) async {
    final tokenEntity = AuthTokenEntity(
      accessToken: accessToken,
      refreshToken: refreshToken,
      user: user,
      fullName: fullName,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );

    final existing = await _database!.authTokenDao.getCurrentToken();
    if (existing != null) {
      await _database!.authTokenDao.updateToken(tokenEntity);
    } else {
      await _database!.authTokenDao.insertToken(tokenEntity);
    }

    if (mobileFormNamesJson != null && mobileFormNamesJson.isNotEmpty) {
      final mobileFormNames = mobileFormNamesJson
          .map((json) => MobileFormName.fromJson(json as Map<String, dynamic>))
          .toList();

      // Mirror MetaService._updateMobileFormDoctypes field set: carry
      // `groupName` and `sortOrder` through the unset / upsert loops so a
      // login here doesn't silently drop those columns relative to a
      // later `resyncMobileConfiguration()` call. (The timestamp-newer
      // check that MetaService also runs is intentionally NOT replicated
      // — AuthService's login path is the entry point that establishes
      // server-side mobile form list as authoritative; no comparison is
      // needed here.)
      final allMetas = await _database!.doctypeMetaDao.findAll();
      for (final meta in allMetas) {
        if (meta.isMobileForm) {
          final updatedMeta = DoctypeMetaEntity(
            doctype: meta.doctype,
            modified: meta.modified,
            serverModifiedAt: meta.serverModifiedAt,
            isMobileForm: false,
            metaJson: meta.metaJson,
            groupName: meta.groupName,
            sortOrder: meta.sortOrder,
          );
          await _database!.doctypeMetaDao.updateDoctypeMeta(updatedMeta);
        }
      }

      for (int i = 0; i < mobileFormNames.length; i++) {
        final mfn = mobileFormNames[i];
        final doctype = mfn.mobileDoctype;
        if (doctype.isEmpty) continue;
        final existingMeta = await _database!.doctypeMetaDao.findByDoctype(
          doctype,
        );

        if (existingMeta != null) {
          final updatedMeta = DoctypeMetaEntity(
            doctype: doctype,
            modified: existingMeta.modified,
            serverModifiedAt: mfn.doctypeMetaModifiedAt,
            isMobileForm: true,
            metaJson: existingMeta.metaJson,
            groupName: mfn.groupName,
            sortOrder: i,
          );
          await _database!.doctypeMetaDao.updateDoctypeMeta(updatedMeta);
        } else {
          final newMeta = DoctypeMetaEntity(
            doctype: doctype,
            modified: null,
            serverModifiedAt: mfn.doctypeMetaModifiedAt,
            isMobileForm: true,
            metaJson: '{}',
            groupName: mfn.groupName,
            sortOrder: i,
          );
          await _database!.doctypeMetaDao.insertDoctypeMeta(newMeta);
        }
      }
    }

    _client!.rest.setBearerToken(accessToken);
    _isAuthenticated = true;
    _cachedUserInfo = (email: user, fullName: fullName ?? user);
    // A fresh credential retires any dead-session latch and cooldown. Without
    // this, a user who re-logs in after a definitive rejection keeps a
    // permanently gated refresh path: the gate short-circuits before any
    // network call, so the only thing that clears the latch — a successful
    // refresh — can never run. The host does not construct a new AuthService
    // on logout, so the latch otherwise survives logout -> login.
    markSessionRecovered();
  }

  /// Authenticates with API key and secret.
  ///
  /// Throws if not initialized or credentials are invalid.
  Future<bool> loginWithApiKey(String apiKey, String apiSecret) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    try {
      _client!.auth.setApiKey(apiKey, apiSecret);
      await _storage.write(key: _keyApiKey, value: apiKey);
      await _storage.write(key: _keyApiSecret, value: apiSecret);
      _isAuthenticated = true;
      return true;
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('API key login failed: $e');
    }
  }

  /// Restores session from stored credentials.
  ///
  /// Tries mobile auth tokens (from DB) first, then OAuth tokens, then API key.
  /// Returns true if a valid session was restored.
  Future<bool> restoreSession({bool isOnline = true}) async {
    final baseUrl = await getBaseUrl();
    if (baseUrl == null) return false;

    if (_client == null) {
      initialize(baseUrl, database: _database);
    }

    // Try mobile auth tokens from database first
    if (_database != null) {
      try {
        final token = await _database!.authTokenDao.getCurrentToken();
        if (token != null && token.accessToken.isNotEmpty) {
          final ageMs = DateTime.now().millisecondsSinceEpoch - token.createdAt;
          if (ageMs >=
              _mobileAccessTokenTtl.inMilliseconds -
                  _tokenRefreshSkew.inMilliseconds) {
            // Aged token. Proactively refreshing BEFORE the boot sync only
            // makes sense ONLINE: offline, callPublic throws NetworkException
            // and the refresh catch would (previously) wipe the token,
            // stranding an offline user — with their cached masters + queued
            // outbox — behind a login screen they cannot pass. So refresh only
            // when online; otherwise fall through to the cached Bearer and let
            // the reactive 401 -> refresh path handle real expiry once
            // connectivity returns.
            if (isOnline) {
              final refreshed = await _tryRefreshMobileAuthToken();
              if (refreshed) {
                _isAuthenticated = true;
                _cachedUserInfo = (
                  email: token.user,
                  fullName: token.fullName ?? token.user,
                );
                return true;
              }
            }
            // Offline, or the refresh could not be redeemed (empty/SSO refresh
            // token, or a transport failure). A DEFINITIVE server rejection
            // (401/403) already deleted the token inside the refresh; if a
            // token row still survives it is our best credential, so install it
            // rather than forcing a re-login the offline user cannot complete.
            final surviving = await _database!.authTokenDao.getCurrentToken();
            if (surviving != null && surviving.accessToken.isNotEmpty) {
              _client!.rest.setBearerToken(surviving.accessToken);
              _isAuthenticated = true;
              _cachedUserInfo = (
                email: surviving.user,
                fullName: surviving.fullName ?? surviving.user,
              );
              return true;
            }
            return false;
          }
          _client!.rest.setBearerToken(token.accessToken);
          _isAuthenticated = true;
          _cachedUserInfo = (
            email: token.user,
            fullName: token.fullName ?? token.user,
          );
          return true;
        }
      } catch (e, st) {
        dev.log(
          'restoreSession: mobile auth token read failed — $e\n$st',
          name: 'Auth',
        );
      }
    }

    final accessToken = await _storage.read(key: _keyOAuthAccessToken);
    final refreshToken = await _storage.read(key: _keyOAuthRefreshToken);
    final expiresAtStr = await _storage.read(key: _keyOAuthExpiresAt);

    if (accessToken != null && accessToken.isNotEmpty) {
      final expiresAt = expiresAtStr != null
          ? int.tryParse(expiresAtStr)
          : null;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (expiresAt == null || expiresAt > now + 60) {
        _client!.rest.setBearerToken(accessToken);
        _isAuthenticated = true;
        return true;
      }
      final oauthClientId = await _storage.read(key: _keyOAuthClientId);
      final oauthClientSecret = await _storage.read(key: _keyOAuthClientSecret);
      if (refreshToken != null &&
          refreshToken.isNotEmpty &&
          oauthClientId != null &&
          oauthClientId.isNotEmpty) {
        try {
          final refreshed = await OAuth2Helper.refreshToken(
            baseUrl: baseUrl,
            clientId: oauthClientId,
            refreshToken: refreshToken,
            clientSecret: oauthClientSecret,
          );
          await _storeOAuthTokens(
            refreshed.accessToken,
            refreshed.refreshToken ?? refreshToken,
            refreshed.expiresIn,
          );
          _client!.rest.setBearerToken(refreshed.accessToken);
          _isAuthenticated = true;
          return true;
        } catch (e, st) {
          dev.log(
            'restoreSession: OAuth refresh failed, clearing tokens — $e\n$st',
            name: 'Auth',
          );
          await _clearOAuthTokens();
        }
      }
    }

    final apiKey = await _storage.read(key: _keyApiKey);
    final apiSecret = await _storage.read(key: _keyApiSecret);
    if (apiKey != null && apiSecret != null) {
      try {
        _client!.auth.setApiKey(apiKey, apiSecret);
        _isAuthenticated = true;
        return true;
      } catch (e, st) {
        dev.log(
          'restoreSession: API key restore failed — $e\n$st',
          name: 'Auth',
        );
        return false;
      }
    }

    return false;
  }

  /// Exchanges OAuth authorization code for tokens and authenticates.
  ///
  /// [code] and [codeVerifier] come from the OAuth redirect.
  /// [clientSecret] is required for confidential OAuth clients.
  Future<bool> loginWithOAuth({
    required String code,
    required String codeVerifier,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    final baseUrl = await getBaseUrl();
    if (baseUrl == null) {
      throw Exception('Base URL not set. Call initialize(baseUrl) first.');
    }
    try {
      final tokens = await OAuth2Helper.exchangeCodeForToken(
        baseUrl: baseUrl,
        clientId: clientId,
        redirectUri: redirectUri,
        code: code,
        codeVerifier: codeVerifier,
        clientSecret: clientSecret,
      );
      dev.log(
        'loginWithOAuth success: access_token length=${tokens.accessToken.length}, refresh_token=${tokens.refreshToken != null ? "set" : "null"}, expires_in=${tokens.expiresIn}',
        name: 'Auth',
      );
      final accessToken = tokens.accessToken.trim();
      if (accessToken.isEmpty) {
        throw Exception('OAuth returned empty access token');
      }
      await _storeOAuthTokens(
        accessToken,
        (tokens.refreshToken ?? '').trim(),
        tokens.expiresIn,
      );
      await _storage.write(key: _keyOAuthClientId, value: clientId);
      if (clientSecret != null && clientSecret.isNotEmpty) {
        await _storage.write(key: _keyOAuthClientSecret, value: clientSecret);
      }
      _client!.rest.setBearerToken(accessToken);
      _isAuthenticated = true;
      return true;
    } catch (e) {
      _isAuthenticated = false;
      throw Exception('OAuth login failed: $e');
    }
  }

  /// Builds OAuth authorize URL and PKCE pair for the login flow.
  ///
  /// Returns a map with `authorize_url` and `code_verifier`.
  static Future<Map<String, String>> prepareOAuthLogin({
    required String baseUrl,
    required String clientId,
    required String redirectUri,
    String scope = 'openid all',
    String? state,
  }) async {
    final pkce = OAuth2Helper.generatePkce();
    final resolvedState =
        state ?? DateTime.now().millisecondsSinceEpoch.toString();
    final url = OAuth2Helper.getAuthorizeUrl(
      baseUrl: baseUrl,
      clientId: clientId,
      redirectUri: redirectUri,
      scope: scope,
      state: resolvedState,
      codeChallenge: pkce.codeChallenge,
    );
    return {
      'authorize_url': url,
      'code_verifier': pkce.codeVerifier,
      'state': resolvedState,
    };
  }

  /// Fetches enabled social providers from backend.
  ///
  /// Accepts either a plain payload or Frappe's `/api/method` envelope:
  /// `{ "message": { "providers": [ ... ] } }`.
  Future<List<Map<String, dynamic>>> fetchSocialLoginProviders() async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    final result = await _client!.rest.callPublic(
      'mobile_auth.get_social_login_providers',
      httpMethod: 'GET',
    );
    final providersRaw = _listFromFrappeResponse(result, 'providers');
    return providersRaw
        .whereType<Map<String, dynamic>>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// Builds a provider-direct authorize URL using backend Social Login Key metadata.
  ///
  /// Backend should return:
  /// `{ "authorize_url": "..." }`
  /// and optionally can return provider metadata as passthrough.
  Future<Map<String, String>> prepareSocialOAuthLogin({
    required String provider,
    required String clientId,
    required String redirectUri,
    String scope = 'openid all',
    String? state,
  }) async {
    if (_client == null) {
      throw Exception('AuthService not initialized. Call initialize() first.');
    }
    final pkce = OAuth2Helper.generatePkce();
    final resolvedState =
        state ?? DateTime.now().millisecondsSinceEpoch.toString();
    final result = await _client!.rest.callPublic(
      'mobile_auth.get_social_authorize_url',
      args: {
        'provider': provider,
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'scope': scope,
        'state': resolvedState,
        'code_challenge': pkce.codeChallenge,
        'code_challenge_method': 'S256',
      },
      httpMethod: 'POST',
    );
    final authorizeUrl = _stringFromFrappeResponse(result, 'authorize_url');
    if (authorizeUrl == null || authorizeUrl.isEmpty) {
      throw Exception(
        'Backend did not return authorize_url for social provider "$provider".',
      );
    }
    return {
      'authorize_url': authorizeUrl,
      'code_verifier': pkce.codeVerifier,
      'state': resolvedState,
    };
  }

  /// Logs out and clears stored credentials.
  ///
  /// If [clearDatabase] is true (default), wipes all local tables.
  Future<void> logout({bool clearDatabase = true}) async {
    try {
      await _client?.auth.logout();
    } catch (e, st) {
      dev.log(
        'logout: server logout failed (continuing local cleanup) — $e\n$st',
        name: 'Auth',
      );
    }
    _client?.rest.setBearerToken(null);
    _isAuthenticated = false;
    _cachedUserInfo = null;
    _roles = [];
    await _storage.delete(key: _keyApiKey);
    await _storage.delete(key: _keyApiSecret);
    await _clearOAuthTokens();
    if (_database != null) {
      await _database!.authTokenDao.deleteAll();
    }
    if (clearDatabase) {
      await AppDatabase.clearAllData();
    }
  }

  /// Clears all stored credentials without touching the database.
  Future<void> clearCredentials() async {
    await _storage.deleteAll();
    _isAuthenticated = false;
    _client = null;
  }

  Future<void> _storeOAuthTokens(
    String accessToken,
    String refreshToken,
    int? expiresIn,
  ) async {
    await _storage.write(key: _keyOAuthAccessToken, value: accessToken);
    await _storage.write(key: _keyOAuthRefreshToken, value: refreshToken);
    if (expiresIn != null) {
      final expiresAt =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000) + expiresIn;
      await _storage.write(
        key: _keyOAuthExpiresAt,
        value: expiresAt.toString(),
      );
    }
  }

  /// Single-flight wrapper: concurrent 401s share ONE in-flight refresh and
  /// its result, instead of each firing a competing refresh.
  ///
  /// The gate in front of it is what stops the storm. Single-flight only
  /// dedupes refreshes that overlap in time; every SUBSEQUENT request wave
  /// started a fresh one, which is how one session produced 215 refresh calls
  /// and tripped the backend's per-user rate limiter.
  Future<bool> _tryRefreshMobileAuthToken() {
    if (!debugRefreshAllowed()) return Future<bool>.value(false);
    return _refreshInFlight ??= _doRefreshMobileAuthToken().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<bool> _doRefreshMobileAuthToken() async {
    // Try mobile auth refresh first.
    if (_database != null) {
      try {
        final token = await _database!.authTokenDao.getCurrentToken();
        if (token != null && token.refreshToken.isNotEmpty) {
          final baseUrl = await getBaseUrl();
          if (baseUrl != null) {
            try {
              // mobile_auth.refresh_token is allow_guest — send it
              // UNAUTHENTICATED (callPublic) so it never touches the shared
              // Bearer. Nulling the Bearer here would race the in-flight
              // concurrent requests, dropping them to Guest -> 403.
              final result = await _client!.rest.callPublic(
                'mobile_auth.refresh_token',
                args: {'refresh_token': token.refreshToken},
              );
              final response = result is Map<String, dynamic>
                  ? result
                  : <String, dynamic>{};
              final newAccessToken = response['access_token'] as String?;
              final newRefreshToken =
                  response['refresh_token'] as String? ?? token.refreshToken;

              if (newAccessToken != null && newAccessToken.isNotEmpty) {
                final updatedToken = AuthTokenEntity(
                  accessToken: newAccessToken,
                  refreshToken: newRefreshToken,
                  user: token.user,
                  fullName: token.fullName,
                  createdAt: DateTime.now().millisecondsSinceEpoch,
                );
                await _database!.authTokenDao.updateToken(updatedToken);
                _client?.rest.setBearerToken(newAccessToken);
                _isAuthenticated = true;
                markSessionRecovered();
                return true;
              }
              // Server returned 200 but no usable access_token. No exception
              // was thrown, so without this the OAuth fallback below runs
              // with no cooldown armed — the next 401 retries the mobile
              // refresh instantly, reproducing the storm this guard exists
              // to prevent.
              debugRecordTransientFailure(rateLimited: false);
            } catch (e, st) {
              // Only a DEFINITIVE rejection (401/403/417) means the refresh
              // token is dead. A transport failure, 5xx, or a 429 lockout must
              // NOT wipe it — the user may simply be offline or rate-limited,
              // and wiping strands their cached masters + queued outbox behind
              // a login screen they cannot pass.
              if (isDefinitiveRefreshRejection(e)) {
                dev.log(
                  '_doRefreshMobileAuthToken: refresh rejected '
                  '(${e is FrappeException ? e.statusCode : '?'}), clearing tokens — $e\n$st',
                  name: 'Auth',
                );
                // Capture the identity BEFORE deleting the row — it is the only
                // place the SDK stores it, and the host needs it to prompt.
                _expiredSessionEmail = token.user;
                _sessionDead = true;
                sessionHealth.value = SessionHealth.expired;
                await _database!.authTokenDao.deleteAll();
              } else {
                final status = e is FrappeException ? e.statusCode : null;
                debugRecordTransientFailure(rateLimited: status == 429);
                dev.log(
                  '_doRefreshMobileAuthToken: refresh failed (status=$status), '
                  'token kept, next attempt after $_refreshCooldownUntil — $e\n$st',
                  name: 'Auth',
                );
              }
            }
          } else {
            // No base URL configured. No exception, so without this the
            // OAuth fallback below runs with no cooldown armed — the next
            // 401 retries the mobile refresh instantly.
            debugRecordTransientFailure(rateLimited: false);
          }
        } else if (token != null) {
          // Token row exists but the refresh token is empty (e.g. an SSO
          // token that never carried one). No exception, so without this
          // the OAuth fallback below runs with no cooldown armed.
          debugRecordTransientFailure(rateLimited: false);
        }
      } catch (e, st) {
        dev.log(
          '_doRefreshMobileAuthToken: token DAO read failed, falling back to OAuth — $e\n$st',
          name: 'Auth',
        );
      }
    }

    // Fallback to OAuth refresh.
    final refreshed = await _tryRefreshOAuthToken();
    if (!refreshed) {
      _isAuthenticated = false;
    }
    return refreshed;
  }

  Future<bool> _tryRefreshOAuthToken() async {
    final baseUrl = await getBaseUrl();
    final refreshToken = await _storage.read(key: _keyOAuthRefreshToken);
    final oauthClientId = await _storage.read(key: _keyOAuthClientId);
    final oauthClientSecret = await _storage.read(key: _keyOAuthClientSecret);
    if (baseUrl == null ||
        refreshToken == null ||
        refreshToken.isEmpty ||
        oauthClientId == null ||
        oauthClientId.isEmpty) {
      return false;
    }
    try {
      final refreshed = await OAuth2Helper.refreshToken(
        baseUrl: baseUrl,
        clientId: oauthClientId,
        refreshToken: refreshToken,
        clientSecret: oauthClientSecret,
      );
      await _storeOAuthTokens(
        refreshed.accessToken,
        refreshed.refreshToken ?? refreshToken,
        refreshed.expiresIn,
      );
      _client?.rest.setBearerToken(refreshed.accessToken);
      return true;
    } catch (e, st) {
      dev.log(
        '_tryRefreshOAuthToken failed, clearing tokens — $e\n$st',
        name: 'Auth',
      );
      await _clearOAuthTokens();
      return false;
    }
  }

  /// Reads [key] as a [List] from Frappe `/api/method` JSON (top-level or `message`).
  static List<dynamic> _listFromFrappeResponse(dynamic result, String key) {
    final root = result is Map<String, dynamic> ? result : <String, dynamic>{};
    final direct = root[key];
    if (direct is List) return direct;
    final msg = root['message'];
    if (msg is Map<String, dynamic>) {
      final nested = msg[key];
      if (nested is List) return nested;
    }
    return const [];
  }

  /// Reads [key] as a non-empty string from Frappe `/api/method` JSON.
  static String? _stringFromFrappeResponse(dynamic result, String key) {
    final root = result is Map<String, dynamic> ? result : <String, dynamic>{};
    final v = root[key]?.toString();
    if (v != null && v.isNotEmpty) return v;
    final msg = root['message'];
    if (msg is Map<String, dynamic>) {
      final v2 = msg[key]?.toString();
      if (v2 != null && v2.isNotEmpty) return v2;
    }
    return null;
  }

  Future<void> _clearOAuthTokens() async {
    await _storage.delete(key: _keyOAuthAccessToken);
    await _storage.delete(key: _keyOAuthRefreshToken);
    await _storage.delete(key: _keyOAuthExpiresAt);
    await _storage.delete(key: _keyOAuthClientId);
    await _storage.delete(key: _keyOAuthClientSecret);
  }
}

/// True only for a DEFINITIVE server rejection of a credential — HTTP 401/403 —
/// which means the stored token is dead and should be cleared so the user
/// re-authenticates. Transport failures ([NetworkException]/timeout) and other
/// statuses (e.g. 417 validation, 5xx) return false so an offline or
/// transiently-failing client never has its token wiped. Used by [AuthService]
/// token refresh; unit-tested in auth_service_refresh_test.dart.
///
/// Classifies on STATUS, not on exception subtype, and that distinction is the
/// whole point: [RestHelper] only produces an [AuthException] for 401/403 when
/// the error body parses as JSON. A non-JSON body — Frappe behind nginx, a proxy
/// error page, an HTML login redirect — returns early as `ApiException(msg, 401)`
/// instead. Matching on [AuthException] therefore missed exactly those cases and
/// KEPT a dead refresh token, leaving the client to 401 -> refresh -> fail
/// forever with no path to re-login.
///
/// Widening to [FrappeException] is safe in both directions: every
/// [NetworkException] construction site passes no status code (so transport
/// failures still return false and an offline user keeps their token), and no
/// site synthesizes a 401/403 — every [ApiException] carries either a real
/// `response.statusCode` or none at all.
bool isDefinitiveAuthRejection(Object error) =>
    error is FrappeException &&
    (error.statusCode == 401 || error.statusCode == 403);

/// True only for a DEFINITIVE rejection **of a refresh token**, meaning the
/// stored token is dead and only a fresh login can recover the session.
///
/// Deliberately WIDER than [isDefinitiveAuthRejection] by one status: **417**.
/// Frappe answers an unredeemable refresh token with
/// `ValidationError: "Invalid or expired refresh token"`, which `RestHelper`
/// surfaces as [ValidationException] (statusCode 417) — NOT 401. Classifying
/// that as transient is what made a dead session retry forever, tripping the
/// backend's per-user rate limiter and leaving no route to re-login.
///
/// Scoping the widening to the refresh call site is what keeps it safe: 417 is
/// Frappe's generic validation status, so [isDefinitiveAuthRejection] must NOT
/// adopt it — there, a 417 from an ordinary document save would wipe a healthy
/// user's tokens.
///
/// 429 stays non-definitive on purpose: the limiter keys on the resolved USER,
/// so a lockout says nothing about whether the token is still good.
bool isDefinitiveRefreshRejection(Object error) =>
    error is FrappeException &&
    (error.statusCode == 401 ||
        error.statusCode == 403 ||
        error.statusCode == 417);
