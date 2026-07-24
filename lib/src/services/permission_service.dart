import '../api/client.dart';
import '../database/app_database.dart';
import '../database/entities/doctype_permission_entity.dart';

/// Syncs and caches user permissions from login response or mobile_auth.permissions API.
/// Use [saveFromLoginResponse] after login; use [syncFromApi] on app launch to refresh.
class PermissionService {
  final FrappeClient _client;
  final AppDatabase _database;

  PermissionService(this._client, this._database);

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

  /// Default true if no row (allow); otherwise use stored value.
  Future<bool> canRead(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.read ?? true;
  }

  Future<bool> canCreate(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.create ?? true;
  }

  Future<bool> canWrite(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.write ?? true;
  }

  Future<bool> canDelete(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.delete ?? true;
  }

  Future<bool> canSubmit(String doctype) async {
    final p = await getDoctypePermission(doctype);
    return p?.submit ?? true;
  }
}
