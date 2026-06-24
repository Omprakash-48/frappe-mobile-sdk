// Integration coverage for the API-layer → push-layer error adapter.
//
// Unlike test/sync/push_engine_test.dart — where every case injects a `send`
// callback that throws a `PushError` subtype BY HAND (`throw ValidationError`,
// `throw TimestampMismatchError`, ...) — these tests drive the REAL dispatch
// (`dispatchHttpSend`, exactly what SyncEngineBuilder wires into the push
// engine) through a real `FrappeClient` backed by a `MockClient` that returns
// the exact JSON envelope a Frappe server returns. This is the integration
// seam where the `FrappeException` hierarchy (api/exceptions.dart) must be
// translated onto the `PushError` hierarchy the engine classifies.
//
// History: this seam had NO adapter — every server rejection escaped as a raw
// `ApiException`/`ValidationException` to the engine's catch-all
// `markFailed(UNKNOWN)`, so the timestamp auto-merge, duplicate reconcile,
// terminal→`paused`, and network-retry paths were all unreachable. These
// tests were written RED to prove that, then `frappeToPushError` /
// `dispatchHttpSend` were added to make them GREEN. They now guard the
// adapter against regression.
//
// Each case asserts the designed classification reached the outbox row:
//   * 417 ValidationError       → `paused`,   error_code VALIDATION (#53)
//   * 417 TimestampMismatchError→ `conflict`, error_code TIMESTAMP_MISMATCH
//   * 409 DuplicateEntryError   → reconciled via L3 lookup (outbox cleared)
//   * 417 LinkExistsError       → error_code LINK_EXISTS
//   * SocketException           → error_code NETWORK

import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart'
    show dispatchHttpSend;
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// The REAL production dispatch — `dispatchHttpSend` is exactly what
/// SyncEngineBuilder wires into the push engine's `send`. The test drives it
/// directly (no mirror) so it can never drift from production behaviour.
PushHttpSendFn realSend(FrappeClient client) =>
    (method, payload, serverName) =>
        dispatchHttpSend(client, method, payload, serverName);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;
  late DoctypeMetaDao metaDao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');
    for (final s in doctypeMetaExtensionsDDL()) {
      await db.execute(s);
    }
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    // Mirror the chetna deployment: server-side naming series (NOT
    // field:mobile_uuid), so idempotency resolves to L3 — the same regime
    // chetna runs in.
    final m = DocTypeMeta(
      name: 'Customer',
      autoname: 'format:CUST-{#####}',
      fields: [f('customer_name', 'Data'), f('mobile_uuid', 'Data')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u-c-1',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': 'ACME',
    });
    outbox = OutboxDao(db);
    metaDao = DoctypeMetaDao(db);
    await outbox.insertPending(
      doctype: 'Customer',
      mobileUuid: 'u-c-1',
      operation: OutboxOperation.insert,
    );
  });

  tearDown(() async => db.close());

  PushEngine buildEngine(
    FrappeClient client, {
    PushServerLookupByUuidFn? lookup,
  }) {
    return PushEngine(
      db: db,
      outboxDao: outbox,
      attachmentDao: PendingAttachmentDao(db),
      metaDao: metaDao,
      pool: ConcurrencyPool(maxConcurrent: 1),
      notifier: SyncStateNotifier(),
      idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
      metaResolver: (dt) async => DocTypeMeta(
        name: dt,
        autoname: 'format:CUST-{#####}',
        fields: [f('customer_name', 'Data'), f('mobile_uuid', 'Data')],
      ),
      childMetaResolver: (dt) async =>
          DocTypeMeta(name: dt, isTable: true, fields: const []),
      send: realSend(client),
      serverFetcher: (_, _) async =>
          throw StateError('serverFetcher not expected in this test'),
      serverLookupByUuid: lookup,
      resolveServerName: (doctype, uuid) async {
        final tn = await metaDao.getTableName(doctype);
        if (tn == null) return null;
        final r = await db.query(
          tn,
          columns: ['server_name'],
          where: 'mobile_uuid = ?',
          whereArgs: [uuid],
          limit: 1,
        );
        return r.isEmpty ? null : r.first['server_name'] as String?;
      },
      attachmentUploader:
          (file, {doctype, docname, fileName, isPrivate = true}) =>
              throw UnimplementedError('no attachments in this test'),
      writeQueueResolver: null,
      attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
      networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    );
  }

  /// A FrappeClient whose transport always replies with [status] + [body]
  /// for the INSERT POST, exactly like a real Frappe server would.
  FrappeClient clientReturning(int status, String body) {
    final mock = MockClient((http.Request req) async {
      // Only the INSERT POST to /api/resource/Customer is exercised here.
      return http.Response(
        body,
        status,
        headers: {'content-type': 'application/json'},
      );
    });
    return FrappeClient('http://test.local', httpClient: mock);
  }

  /// A FrappeClient whose transport throws [error] on the request — models a
  /// real connectivity failure (rest_helper maps SocketException →
  /// NetworkException).
  FrappeClient clientThrowing(Object error) {
    final mock = MockClient((http.Request req) async => throw error);
    return FrappeClient('http://test.local', httpClient: mock);
  }

  Future<Map<String, Object?>> outboxRow() async {
    final rows = await db.query(
      'outbox',
      where: 'mobile_uuid = ?',
      whereArgs: ['u-c-1'],
    );
    expect(
      rows,
      hasLength(1),
      reason: 'INSERT failed, so the slim outbox row should still be present',
    );
    return rows.single;
  }

  test(
    'server validate() hook (HTTP 417) → row PAUSED with error_code VALIDATION',
    () async {
      // Exact Frappe 417 envelope for a validate()-hook ValidationError.
      const body =
          '{"exc_type":"ValidationError",'
          '"_server_messages":"[\\"Age must be between 15 and 49\\"]",'
          '"exception":"frappe.exceptions.ValidationError: Age must be between 15 and 49"}';
      final engine = buildEngine(clientReturning(417, body));

      await engine.runOnce();

      final row = await outboxRow();
      // DESIGNED behaviour (push_engine.dart `on ServerRejection` → markPaused
      // when toErrorCode().isTerminal). ACTUAL: 'failed' / 'UNKNOWN'.
      expect(
        row['error_code'],
        ErrorCode.VALIDATION.wireName, // 'VALIDATION'
        reason:
            'A 417 validate-hook failure must classify as VALIDATION, '
            'not UNKNOWN — proving rest_helper.ValidationException reached '
            'the engine as a typed PushError.',
      );
      expect(
        row['state'],
        OutboxState.paused.wireName, // 'paused'
        reason:
            'A terminal validation rejection must be PARKED (paused), '
            'not left in failed where the retry loop re-attempts it.',
      );
    },
  );

  test('optimistic-lock conflict (HTTP 417) → row CONFLICT with error_code '
      'TIMESTAMP_MISMATCH', () async {
    // Frappe's TimestampMismatchError extends ValidationError, so it is raised
    // at HTTP 417 (NOT 409 — 409 is NameError/DuplicateEntry). Routing keys on
    // exc_type, so this still reaches the auto-merge path. This case doubles
    // as the H3 regression guard: a genuine timestamp mismatch carries
    // exc_type and must still classify as TIMESTAMP_MISMATCH after the
    // unknown-409 default was removed.
    const body =
        '{"exc_type":"TimestampMismatchError",'
        '"exception":"frappe.exceptions.TimestampMismatchError: '
        'Document has been modified after you have opened it"}';
    final engine = buildEngine(clientReturning(417, body));

    await engine.runOnce();

    final row = await outboxRow();
    expect(
      row['error_code'],
      ErrorCode.TIMESTAMP_MISMATCH.wireName, // 'TIMESTAMP_MISMATCH'
      reason:
          'A timestamp mismatch must classify as TIMESTAMP_MISMATCH '
          'so the three-way auto-merge path runs — not UNKNOWN.',
    );
    expect(row['state'], OutboxState.conflict.wireName); // 'conflict'
  });

  test('duplicate INSERT (server already has mobile_uuid) → reconcile via L3 '
      'lookup, NOT a failed row', () async {
    // Frappe raises DuplicateEntryError as HTTP 409 with this exc_type.
    const body =
        '{"exc_type":"DuplicateEntryError",'
        '"exception":"frappe.exceptions.DuplicateEntryError: Customer u-c-1 already exists"}';
    // L3 idempotency probe: the prior POST landed; lookup finds the row.
    final engine = buildEngine(
      clientReturning(409, body),
      lookup: (doctype, uuid) async => {
        'name': 'CUST-existing-9',
        'modified': '2026-01-01 00:00:00',
        'mobile_uuid': uuid,
        'customer_name': 'ACME',
      },
    );

    await engine.runOnce();

    // DESIGNED: _resolveDuplicate adopts the existing server doc and writes
    // back as a success — the outbox row is DONE (deleted) and the local
    // row is marked synced. ACTUAL: 409→ApiException→markFailed(UNKNOWN),
    // outbox row stranded in 'failed'.
    final remaining = await db.query(
      'outbox',
      where: 'mobile_uuid = ?',
      whereArgs: ['u-c-1'],
    );
    expect(
      remaining,
      isEmpty,
      reason:
          'A recovered duplicate must clear the outbox (markDone), '
          'not leave a failed row needing manual retry.',
    );
    final doc = (await db.query('docs__customer')).single;
    expect(doc['server_name'], 'CUST-existing-9');
    expect(doc['sync_status'], 'synced');
  });

  test('link-constraint failure (exc_type LinkExistsError) → error_code '
      'LINK_EXISTS', () async {
    // Frappe LinkExistsError extends ValidationError → HTTP 417.
    const body =
        '{"exc_type":"LinkExistsError",'
        '"exception":"frappe.exceptions.LinkExistsError: Cannot delete, linked"}';
    final engine = buildEngine(clientReturning(417, body));

    await engine.runOnce();

    final row = await outboxRow();
    // DESIGNED: `on LinkExistsError` → markFailed(LINK_EXISTS). ACTUAL:
    // 417→ValidationException→UNKNOWN.
    expect(row['error_code'], ErrorCode.LINK_EXISTS.wireName); // 'LINK_EXISTS'
  });

  test('connectivity failure (SocketException) → error_code NETWORK '
      '', () async {
    final engine = buildEngine(
      clientThrowing(const SocketException('Network is unreachable')),
    );

    await engine.runOnce();

    final row = await outboxRow();
    // DESIGNED: NetworkException → NetworkError → markFailed(NETWORK), a
    // retryable bucket that retryAll re-attempts. ACTUAL: UNKNOWN, which
    // reads as a hard failure.
    expect(
      row['error_code'],
      ErrorCode.NETWORK.wireName, // 'NETWORK'
      reason:
          'A transient connectivity failure must classify as NETWORK, '
          'not UNKNOWN — otherwise it reads as a permanent error.',
    );
  });

  test('session expiry (HTTP 401) → retryable NETWORK, NOT terminal paused '
      '(B2)', () async {
    // A 401 is session expiry, not a permanent permission denial. After the
    // user re-authenticates the queued rows must still push, so it must land
    // in a retryable bucket — never `paused` like a 403.
    const body =
        '{"exc_type":"PermissionError",'
        '"exception":"frappe.exceptions.AuthenticationError: session expired"}';
    final engine = buildEngine(clientReturning(401, body));

    await engine.runOnce();

    final row = await outboxRow();
    expect(
      row['error_code'],
      ErrorCode.NETWORK.wireName,
      reason:
          'A 401 must be retryable (NETWORK), not terminal PERMISSION_DENIED.',
    );
    expect(
      row['state'],
      OutboxState.failed.wireName,
      reason: 'A 401 must NOT be paused — re-auth + retry must recover it.',
    );
  });

  test('permission denied (HTTP 403) → terminal PERMISSION_DENIED, paused '
      '(B2)', () async {
    // A genuine 403 IS terminal — the user lacks permission; retry can't help.
    const body =
        '{"exc_type":"PermissionError",'
        '"exception":"frappe.exceptions.PermissionError: not permitted"}';
    final engine = buildEngine(clientReturning(403, body));

    await engine.runOnce();

    final row = await outboxRow();
    expect(row['error_code'], ErrorCode.PERMISSION_DENIED.wireName);
    expect(row['state'], OutboxState.paused.wireName);
  });

  test('409 without exc_type → generic ServerRejection, NOT timestamp '
      'mismatch (H3)', () async {
    // A 409 with no exc_type may be a duplicate-name or custom-app conflict,
    // not an optimistic-lock mismatch. Defaulting it to TimestampMismatchError
    // triggers a refresh+retry that hits the same 409 and loops until the
    // budget exhausts, then mislabels the cause. Treat unknown 409s as a
    // generic ServerRejection (UNKNOWN) instead.
    const body = '{"exception":"Duplicate name CUST-1 already exists"}';
    final engine = buildEngine(clientReturning(409, body));

    await engine.runOnce();

    final row = await outboxRow();
    expect(
      row['error_code'],
      isNot(ErrorCode.TIMESTAMP_MISMATCH.wireName),
      reason: 'unknown 409 must not be auto-classified as timestamp mismatch',
    );
    expect(row['error_code'], ErrorCode.UNKNOWN.wireName);
  });
}
