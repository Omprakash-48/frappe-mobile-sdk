import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../database/schema/system_columns.dart';
import '../database/sqlite_utils.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';
import '../sync/child_table_info.dart';
import '../utils/attachment_paths.dart';
import '../utils/sdk_log.dart';

/// Docfield types whose value is a single file reference that the offline
/// producer must copy + queue for upload.
const Set<String> kAttachmentFieldTypes = {'Attach', 'Attach Image', 'Image'};

/// Writes a form-save payload to the per-doctype `docs__<doctype>` parent
/// table and `docs__<child_doctype>` child tables in a single transaction.
///
/// `docs__<doctype>` is the source of truth for offline reads
/// ([UnifiedResolver]) and writes (push) post-retirement. Used by
/// [OfflineRepository.saveDocument] for offline saves and by
/// [OfflineRepository.applyServerDocument] for pulled rows.
///
/// `mobile_uuid` is the parent PK; [markSynced] reconciles `server_name`
/// onto the same row after a successful push.
class LocalWriter {
  final Database _db;
  final MetaResolverFn _metaResolver;
  final Uuid _uuid;

  LocalWriter(this._db, this._metaResolver, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  static const _systemParentColumns = systemParentColumnNames;
  static const _systemChildColumns = systemChildColumnNames;

  /// Convenience: opens a single-shot transaction and delegates to
  /// [writeParentInTxn]. Pre-resolves the parent + child metas BEFORE
  /// opening the txn so the resolver — which typically queries the
  /// `doctype_meta` table through the outer Database — does not deadlock
  /// against the in-flight write txn (sqflite serializes outer reads
  /// behind the txn). Returns the parent's `mobile_uuid`.
  Future<String> writeParent({
    required String parentDoctype,
    required Map<String, dynamic> data,
    String? serverName,
    String? syncOp,
    String? pushBasePayload,
  }) async {
    final rawUuid = data['mobile_uuid'] as String?;
    final mobileUuid = (rawUuid != null && rawUuid.isNotEmpty)
        ? rawUuid
        : _uuid.v4();

    // Pre-resolve metas outside the txn (deadlock guard).
    final parentMeta = await _metaResolver(parentDoctype);
    final childMetasByDoctype = <String, DocTypeMeta>{};
    for (final f in parentMeta.fields) {
      final opt = f.options;
      if ((f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') &&
          opt != null &&
          opt.isNotEmpty) {
        try {
          childMetasByDoctype[opt] = await _metaResolver(opt);
        } catch (e, st) {
          sdkLog(
            'LocalWriter.writeParent: child meta pre-resolve failed for '
            '$opt — $e\n$st',
          );
        }
      }
    }

    await _db.transaction((txn) async {
      await writeParentInTxn(
        txn: txn,
        parentDoctype: parentDoctype,
        mobileUuid: mobileUuid,
        data: data,
        serverName: serverName,
        syncOp: syncOp,
        pushBasePayload: pushBasePayload,
        parentMeta: parentMeta,
        childMetasByDoctype: childMetasByDoctype,
      );
    });
    return mobileUuid;
  }

  /// Writes (or replaces) a parent document + its child rows into the
  /// per-doctype tables, inside a caller-supplied [Transaction], so the
  /// parent + child writes can be part of a wider spanning txn (e.g. the
  /// `OfflineRepository.saveDocument` save which also enqueues an outbox
  /// row in the same atomic unit).
  ///
  /// [data] is the form payload. `Table` / `Table MultiSelect` fields are
  /// split out into the child doctype's own table.
  ///
  /// `data['mobile_uuid']` becomes the parent PK so a later push can
  /// reconcile `server_name` onto the same row.
  ///
  /// [serverName] — when non-null (server-first save returned a name),
  /// `server_name` is populated and `sync_status='synced'`. Otherwise
  /// `sync_status='dirty'`.
  ///
  /// Silently no-ops if the parent table doesn't exist yet (initial sync
  /// hasn't run).
  ///
  /// [parentMeta] is REQUIRED and [childMetasByDoctype] SHOULD hold every
  /// child doctype's meta — both MUST be pre-resolved by the caller OUTSIDE
  /// this txn. Meta is never resolved here: [_metaResolver] queries
  /// `doctype_meta` through the outer Database, which would hang on the
  /// sqflite write queue if invoked while this txn holds it. Child doctypes
  /// absent from [childMetasByDoctype] are skipped (rows not written).
  Future<void> writeParentInTxn({
    required Transaction txn,
    required String parentDoctype,
    required String mobileUuid,
    required Map<String, dynamic> data,
    String? serverName,
    String? syncOp,
    String? pushBasePayload,
    required DocTypeMeta parentMeta,
    Map<String, DocTypeMeta>? childMetasByDoctype,
  }) async {
    // [parentMeta] / [childMetasByDoctype] are pre-resolved by the caller
    // (see doc above). NEVER resolve meta in-txn: querying the outer
    // Database while this txn holds the sqflite write queue hangs forever
    // on the non-reentrant lock (a Dart deadlock, not SQLITE_BUSY).
    final parentTable = normalizeDoctypeTableName(parentDoctype);
    if (!await sqliteTableExists(txn, parentTable)) return;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

    // Offline attachment producer: any attach-field value that is still a
    // local file path is copied-at-pick already, so here we only queue it
    // (with its exact parent/child coordinates) and replace the stored value
    // with a `pending:<id>` marker the push pipeline resolves to a file_url.
    final attachDao = PendingAttachmentDao(txn);
    Future<Object?> queueIfLocalAttachment({
      required Object? value,
      required String fieldType,
      required String rowUuid,
      required String rowDoctype,
      required String fieldname,
    }) async {
      if (!kAttachmentFieldTypes.contains(fieldType)) return value;
      if (!isLocalAttachmentPath(value)) return value;
      final path = (value as String).trim();
      // Idempotency: the (parent_uuid, parent_fieldname) index is not UNIQUE,
      // so a re-pick/re-save would otherwise stack duplicate rows. Drop any
      // prior queue row for this exact field before inserting the fresh one.
      await txn.delete(
        'pending_attachments',
        where: 'parent_uuid = ? AND parent_fieldname = ?',
        whereArgs: [rowUuid, fieldname],
      );
      final id = await attachDao.enqueue(
        parentDoctype: rowDoctype,
        parentUuid: rowUuid,
        parentFieldname: fieldname,
        topParentUuid: mobileUuid,
        topParentDoctype: parentDoctype,
        localPath: path,
        fileName: path.split('/').last,
      );
      return 'pending:$id';
    }

    final childInfos = <String, ChildTableInfo>{};
    for (final f in parentMeta.fields) {
      final ft = f.fieldtype;
      final fn = f.fieldname;
      final opt = f.options;
      if ((ft == 'Table' || ft == 'Table MultiSelect') &&
          fn != null &&
          opt != null &&
          opt.isNotEmpty) {
        final cm = childMetasByDoctype?[opt];
        if (cm == null) {
          // Caller omitted this child's meta (not synced) — skip its rows.
          // Resolving here would hang on the sqflite write queue (see above).
          sdkLog(
            'LocalWriter.writeParentInTxn: child meta not supplied for '
            '$opt — skipping child rows',
          );
          continue;
        }
        childInfos[fn] = ChildTableInfo(opt, cm);
      }
    }

    final normFields = parentMeta.normFieldNames;

    final parentRow = <String, Object?>{
      'mobile_uuid': mobileUuid,
      'server_name': serverName,
      'sync_status': syncOp != null
          ? 'dirty'
          : (serverName != null ? 'synced' : 'dirty'),
      'sync_op': ?syncOp,
      'docstatus': _coerceInt(data['docstatus']) ?? 0,
      'modified': data['modified']?.toString(),
      'local_modified': nowMs,
      'push_base_payload': ?pushBasePayload,
    };

    for (final f in parentMeta.fields) {
      final name = f.fieldname;
      final type = f.fieldtype;
      if (name == null) continue;
      if (type == 'Table' || type == 'Table MultiSelect') continue;
      final sqlType = sqliteColumnTypeFor(type);
      if (sqlType == null) continue;
      if (_systemParentColumns.contains(name)) continue;
      if (!data.containsKey(name)) continue;

      var v = _coerce(data[name], sqlType);
      v = await queueIfLocalAttachment(
        value: v,
        fieldType: type,
        rowUuid: mobileUuid,
        rowDoctype: parentDoctype,
        fieldname: name,
      );
      parentRow[name] = v;

      if (isLinkFieldType(type)) {
        // Default to server-known. When the form picker selects a
        // local-only target row, the caller is expected to pass
        // `<field>__is_local: 1` in `data` directly (handled below).
        parentRow['${name}__is_local'] =
            _coerceInt(data['${name}__is_local']) ?? 0;
      }
      if (normFields.contains(name) && sqlType == 'TEXT') {
        parentRow['${name}__norm'] = normalizeForSearch(v?.toString());
      }
    }

    await txn.insert(
      parentTable,
      parentRow,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    for (final entry in childInfos.entries) {
      final fieldname = entry.key;
      final childInfo = entry.value;
      final childTable = normalizeDoctypeTableName(childInfo.doctype);
      if (!await sqliteTableExists(txn, childTable)) continue;

      await txn.delete(
        childTable,
        where: 'parent_uuid = ? AND parentfield = ?',
        whereArgs: [mobileUuid, fieldname],
      );

      final list = data[fieldname];
      if (list is! List) continue;

      for (var idx = 0; idx < list.length; idx++) {
        final raw = list[idx];
        if (raw is! Map) continue;
        final cr = Map<String, dynamic>.from(raw);
        final rawChildUuid = cr['mobile_uuid'] as String?;
        final childUuid = (rawChildUuid != null && rawChildUuid.isNotEmpty)
            ? rawChildUuid
            : _uuid.v4();
        final childServerName = cr['name']?.toString();

        final childRow = <String, Object?>{
          'mobile_uuid': childUuid,
          'server_name': childServerName,
          'parent_uuid': mobileUuid,
          'parent_doctype': parentDoctype,
          'parentfield': fieldname,
          'idx': idx,
          'modified': cr['modified']?.toString(),
        };

        for (final cf in childInfo.meta.fields) {
          final cn = cf.fieldname;
          final ct = cf.fieldtype;
          if (cn == null) continue;
          if (ct == 'Table' || ct == 'Table MultiSelect') continue;
          final cSqlType = sqliteColumnTypeFor(ct);
          if (cSqlType == null) continue;
          if (_systemChildColumns.contains(cn)) continue;
          if (!cr.containsKey(cn)) continue;

          var v = _coerce(cr[cn], cSqlType);
          v = await queueIfLocalAttachment(
            value: v,
            fieldType: ct,
            rowUuid: childUuid,
            rowDoctype: childInfo.doctype,
            fieldname: cn,
          );
          childRow[cn] = v;
          if (isLinkFieldType(ct)) {
            childRow['${cn}__is_local'] =
                _coerceInt(cr['${cn}__is_local']) ?? 0;
          }
        }

        await txn.insert(
          childTable,
          childRow,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    }
  }

  /// Updates `server_name` + `sync_status='synced'` on the parent row
  /// after push sync confirms the doc landed on the server. Called by
  /// [ResponseWriteback] on a successful push response.
  Future<void> markSynced({
    required String parentDoctype,
    required String mobileUuid,
    required String serverName,
  }) async {
    final parentTable = normalizeDoctypeTableName(parentDoctype);
    await _db.transaction((txn) async {
      if (!await sqliteTableExists(txn, parentTable)) return;
      await txn.update(
        parentTable,
        <String, Object?>{'server_name': serverName, 'sync_status': 'synced'},
        where: 'mobile_uuid = ?',
        whereArgs: [mobileUuid],
      );
    });
  }

  Object? _coerce(Object? v, String sqlType) {
    if (v == null) return null;
    if (sqlType == 'TEXT') {
      if (v is String) return v;
      return v.toString();
    }
    if (sqlType == 'INTEGER') return _coerceInt(v);
    if (sqlType == 'REAL') {
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString().trim());
    }
    return v;
  }

  int? _coerceInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v.toInt();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }
}
