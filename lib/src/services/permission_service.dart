import '../api/client.dart';
import '../database/app_database.dart';
import '../database/entities/doctype_permission_entity.dart';
import '../utils/sdk_log.dart';

/// Syncs and caches user permissions from login response or mobile_auth.permissions API.
/// Use [saveFromLoginResponse] after login; use [syncFromApi] on app launch to refresh.
class PermissionService {
  final FrappeClient _client;
  final AppDatabase _database;

  /// [onCacheMiss] is invoked with the doctype whenever no synced permission
  /// row exists for it. Optional and named so every existing call site is
  /// unaffected.
  PermissionService(
    this._client,
    this._database, {
    void Function(String doctype)? onCacheMiss,
  }) : _onCacheMiss = onCacheMiss;

  final void Function(String doctype)? _onCacheMiss;

  /// Save permissions from login response.
  /// [permissions] can be:
  /// - List: [ { "doctype": "X", "read": true, "write": false, ... }, ... ]
  /// - Map (legacy): { "roles": [...], "permissions": { "DocType": { "read": true, ... } } }
  Future<void> saveFromLoginResponse(dynamic permissions) async {
    final entities = _parsePermissions(permissions);
    if (entities.isNotEmpty) {
      // Login payloads may be a SUBSET (e.g. an SSO endpoint returning only
      // role-matched doctypes), so upsert — never wipe the fuller cached set.
      await _database.doctypePermissionDao.upsertAll(entities);
    }
  }

  /// Call mobile_auth.permissions API and refresh local cache.
  /// Accepts permissions as list or map (same as [saveFromLoginResponse]).
  ///
  /// [timeout], when supplied, fast-fails the call instead of waiting on
  /// the default 30s × 3-retry budget — pass a short value (e.g. 10s)
  /// when this is gating a splash/boot path so a wrong-server or down
  /// server surfaces a [NetworkException] quickly.
  Future<Map<String, dynamic>?> syncFromApi({Duration? timeout}) async {
    final result = await _client.rest.get(
      '/api/v2/method/mobile_auth.permissions',
      timeout: timeout,
      maxRetries: timeout != null ? 0 : null,
    );
    if (result is! Map<String, dynamic>) return null;
    final data = result['data'] as Map<String, dynamic>? ?? result;
    // Authoritative full set → full-replace so doctypes revoked server-side are
    // pruned. `replaceAll` no-ops on empty, so a transient server error (which
    // returns an empty permissions list) can never wipe a good cache.
    final entities = _parsePermissions(data['permissions']);
    await _database.doctypePermissionDao.replaceAll(entities);
    return data;
  }

  /// Parse a login / permissions payload into entities. Accepts both shapes the
  /// backend can emit:
  /// - List (current): `[{ "doctype": "X", "read": true|1|"1", ... }]`
  /// - Map (legacy): `{ "permissions": { "X": { "read": ... } } }`
  /// Flag coercion (bool / int / string) lives in [DoctypePermissionEntity.fromApiMap].
  List<DoctypePermissionEntity> _parsePermissions(dynamic permissions) {
    final entities = <DoctypePermissionEntity>[];
    if (permissions == null) return entities;
    if (permissions is List) {
      for (final item in permissions) {
        if (item is Map) {
          final m = Map<String, dynamic>.from(item);
          final doctype = m['doctype']?.toString();
          if (doctype != null && doctype.isNotEmpty) {
            entities.add(DoctypePermissionEntity.fromApiMap(doctype, m));
          }
        }
      }
    } else if (permissions is Map) {
      final inner = permissions['permissions'];
      if (inner is Map) {
        inner.forEach((key, value) {
          if (value is Map) {
            entities.add(
              DoctypePermissionEntity.fromApiMap(
                key.toString(),
                Map<String, dynamic>.from(value),
              ),
            );
          }
        });
      }
    }
    return entities;
  }

  Future<DoctypePermissionEntity?> getDoctypePermission(String doctype) async {
    return _database.doctypePermissionDao.findByDoctype(doctype);
  }

  /// Resolves one permission flag.
  ///
  /// A MISS — no synced row for [doctype] — defaults to ALLOW, preserving
  /// historical behaviour, but is reported via [_onCacheMiss] and logged. A miss
  /// means the UI is gating on an assumption rather than on the server's matrix:
  /// the doctype is absent from the `mobile_auth.permissions` payload, or the
  /// sync has not run or failed. The server still enforces the real permission,
  /// so the user-visible symptom is a 403 AFTER filling in a form.
  Future<bool> _flag(
    String doctype,
    bool Function(DoctypePermissionEntity) pick,
  ) async {
    final p = await getDoctypePermission(doctype);
    if (p == null) {
      _onCacheMiss?.call(doctype);
      sdkLog(
        'PermissionService: no synced permission row for "$doctype" '
        '- defaulting to allow',
      );
      return true;
    }
    return pick(p);
  }

  /// Default true if no row (allow); otherwise use stored value.
  Future<bool> canRead(String doctype) => _flag(doctype, (p) => p.read);

  Future<bool> canCreate(String doctype) => _flag(doctype, (p) => p.create);

  Future<bool> canWrite(String doctype) => _flag(doctype, (p) => p.write);

  Future<bool> canDelete(String doctype) => _flag(doctype, (p) => p.delete);

  Future<bool> canSubmit(String doctype) => _flag(doctype, (p) => p.submit);
}
