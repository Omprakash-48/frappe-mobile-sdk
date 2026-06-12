import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/concurrency/write_queue.dart';
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
    final m = DocTypeMeta(
      name: 'Customer',
      autoname: 'field:mobile_uuid',
      fields: [f('customer_name', 'Data')],
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

  PushEngine buildEngine({
    required PushHttpSendFn send,
    PushServerFetchFn? serverFetcher,
    PushServerLookupByUuidFn? serverLookupByUuid,
    DocTypeMeta? customMeta,
    IdempotencyStrategy? idempotencyStrategy,
    WriteQueue Function(String doctype)? writeQueueResolver,
    Future<void> Function()? onDrainComplete,
  }) {
    return PushEngine(
      onDrainComplete: onDrainComplete,
      db: db,
      outboxDao: outbox,
      attachmentDao: PendingAttachmentDao(db),
      metaDao: metaDao,
      pool: ConcurrencyPool(maxConcurrent: 2),
      notifier: SyncStateNotifier(),
      idempotencyStrategy:
          idempotencyStrategy ?? IdempotencyStrategy(serverHasDedupHook: false),
      metaResolver: (dt) async =>
          customMeta ??
          DocTypeMeta(
            name: dt,
            autoname: 'field:mobile_uuid',
            fields: [f('customer_name', 'Data')],
          ),
      childMetaResolver: (dt) async =>
          DocTypeMeta(name: dt, isTable: true, fields: const []),
      send: send,
      serverFetcher:
          serverFetcher ??
          (_, _) async =>
              throw StateError('serverFetcher not expected in this test'),
      serverLookupByUuid: serverLookupByUuid,
      resolveServerName: (doctype, uuid) async {
        // Resolve via the in-memory DB's table for this doctype.
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
      writeQueueResolver: writeQueueResolver,
      attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
      networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    );
  }

  test(
    'happy path INSERT: sends payload, writes back name + marks synced',
    () async {
      final engine = buildEngine(
        send: (method, payload, serverName) async {
          expect(method, 'POST');
          expect(payload['doctype'], 'Customer');
          expect(payload['customer_name'], 'ACME');
          expect(payload['mobile_uuid'], 'u-c-1');
          return {'name': 'CUST-1', 'modified': '2026-01-01 00:00:00'};
        },
      );
      await engine.runOnce();
      final row = (await db.query('docs__customer')).first;
      expect(row['server_name'], 'CUST-1');
      expect(row['sync_status'], 'synced');
      expect(row['modified'], '2026-01-01 00:00:00');
      // Slim outbox: markDone deletes the row outright. After a successful
      // push the outbox is empty for this uuid.
      final remaining = await db.query(
        'outbox',
        where: 'mobile_uuid = ?',
        whereArgs: ['u-c-1'],
      );
      expect(remaining, isEmpty);
    },
  );

  test('concurrent runOnce() does not double-dispatch the same row', () async {
    // B1 (PR#36 round-4): runOnce() had no reentrancy guard. Two concurrent
    // callers (user save, connectivity restore, syncNow) each reset in_flight
    // rows back to pending and re-fetch the outbox, so a single pending row is
    // dispatched twice in parallel. Park the first dispatch on a gate so the
    // second call races in while the first is still in flight.
    var sendCount = 0;
    final gate = Completer<void>();
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        sendCount++;
        if (sendCount == 1) await gate.future; // hold the first dispatch
        return {'name': 'CUST-1', 'modified': '2026-01-01 00:00:00'};
      },
    );

    final a = engine.runOnce();
    final b = engine.runOnce();
    // Let both calls run through resetInFlightToPending + outbox fetch.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    gate.complete();
    await a.catchError((_) {});
    await b.catchError((_) {});

    expect(
      sendCount,
      1,
      reason: 'a concurrent runOnce must coalesce, not re-dispatch in flight',
    );
  });

  test('UPDATE: writes back, marks synced', () async {
    await db.update(
      'docs__customer',
      {'server_name': 'CUST-1', 'modified': '2026-01-01'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    // server_name lives on docs__ now; outbox just records the operation.
    await db.update(
      'outbox',
      {'operation': 'UPDATE'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        expect(method, 'PUT');
        expect(serverName, 'CUST-1');
        expect(
          payload['modified'],
          '2026-01-01',
          reason: 'check_if_latest needs the local snapshot modified',
        );
        return {'name': 'CUST-1', 'modified': '2026-01-15 10:00:00'};
      },
    );
    await engine.runOnce();
    final row = (await db.query('docs__customer')).first;
    expect(row['modified'], '2026-01-15 10:00:00');
    expect(row['sync_status'], 'synced');
  });

  test('NetworkError → retries up to N then markFailed(NETWORK)', () async {
    // Default test meta uses autoname=field:mobile_uuid → L1 path. L3's
    // pre-retry GET is gated on preRetryGetCheck, so it must NOT fire here
    // and the attempt count is purely the send retry count.
    var attempts = 0;
    final engine = buildEngine(
      send: (m, p, sn) async {
        attempts++;
        throw NetworkError(message: 'offline');
      },
    );
    await engine.runOnce();
    final row = await outbox.findById(1);
    expect(row!.state, OutboxState.failed);
    expect(row.errorCode, ErrorCode.NETWORK);
    expect(
      attempts,
      greaterThanOrEqualTo(2),
      reason: 'must retry at least once before giving up',
    );
  });

  test('TimeoutError surfaces with TIMEOUT errorCode', () async {
    final engine = buildEngine(
      send: (m, p, sn) async => throw TimeoutError(message: 'too slow'),
    );
    await engine.runOnce();
    final row = await outbox.findById(1);
    expect(row!.errorCode, ErrorCode.TIMEOUT);
  });

  test(
    'DeadlockError is transient — retried then succeeds (not markFailed)',
    () async {
      // The deadlock victim rolled back, so the INSERT never committed; a
      // retry against the now-uncontended tabSeries row succeeds. Before the
      // fix the deadlock escaped as a raw ApiException → markFailed(UNKNOWN).
      var attempts = 0;
      final engine = buildEngine(
        send: (m, p, sn) async {
          attempts++;
          if (attempts < 3) {
            throw DeadlockError(message: 'Deadlock found (1213)');
          }
          return {'name': 'CUST-9', 'modified': '2026-01-01 00:00:00'};
        },
      );
      await engine.runOnce();

      expect(attempts, 3, reason: 'two deadlocks then success');
      final row = (await db.query('docs__customer')).first;
      expect(row['server_name'], 'CUST-9');
      expect(row['sync_status'], 'synced');
      // Slim outbox: a completed push deletes the row.
      expect(await outbox.findById(1), isNull);
    },
  );

  test(
    'DeadlockError exhausting all retries → markFailed(NETWORK), retryable',
    () async {
      var attempts = 0;
      final engine = buildEngine(
        send: (m, p, sn) async {
          attempts++;
          throw DeadlockError(message: 'Deadlock found (1213)');
        },
      );
      await engine.runOnce();

      expect(
        attempts,
        greaterThanOrEqualTo(2),
        reason: 'retries before giving up',
      );
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      // NETWORK (not UNKNOWN) so the error UI groups it as a retryable
      // transient under retryAll.
      expect(row.errorCode, ErrorCode.NETWORK);
    },
  );

  test(
    'BlockedByUpstream from UuidRewriter (unresolved Link) → markBlocked',
    () async {
      // Add an unresolved local Link to a non-existent target.
      await db.execute('ALTER TABLE docs__customer ADD COLUMN territory TEXT');
      await db.execute(
        'ALTER TABLE docs__customer ADD COLUMN territory__is_local INTEGER',
      );
      await db.update(
        'docs__customer',
        {'territory': 'u-tgt-not-yet', 'territory__is_local': 1},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );

      var sendCalled = false;
      final engine = buildEngine(
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: 'field:mobile_uuid',
          fields: [
            f('customer_name', 'Data'),
            f('territory', 'Link', options: 'Territory'),
          ],
        ),
        send: (m, p, sn) async {
          sendCalled = true;
          return {'name': 'X', 'modified': '2026'};
        },
      );
      await engine.runOnce();
      expect(
        sendCalled,
        isFalse,
        reason: 'send must NOT be called when payload assembly blocks',
      );
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.blocked);
    },
  );

  test(
    'terminal ServerRejection (417) → markPaused, not retried (#53)',
    () async {
      final engine = buildEngine(
        send: (m, p, sn) async => throw ServerRejection(
          status: 417,
          rawBody: '{"exc_type":"MandatoryError"}',
        ),
      );
      await engine.runOnce();
      final row = await outbox.findById(1);
      // MANDATORY is terminal — parking it out of the retry loop avoids the
      // infinite-retry deadlock the app previously string-matched 417 to detect.
      expect(row!.state, OutboxState.paused);
      expect(row.errorCode, ErrorCode.MANDATORY);
      expect(row.isTerminal, isTrue);
      // The drain must not pick it back up.
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
    },
  );

  test(
    'non-terminal ServerRejection (500) → markFailed, still retryable (#53)',
    () async {
      final engine = buildEngine(
        send: (m, p, sn) async => throw ServerRejection(
          status: 500,
          rawBody: '{"exc_type":"SomeServerError"}',
        ),
      );
      await engine.runOnce();
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.isTerminal, isFalse);
    },
  );

  test('LinkExistsError on DELETE → markFailed with structured JSON', () async {
    await db.update(
      'docs__customer',
      {'server_name': 'CUST-1'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    // server_name lives on docs__; outbox only carries the operation.
    await db.update(
      'outbox',
      {'operation': 'DELETE'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    final engine = buildEngine(
      send: (m, p, sn) async => throw LinkExistsError(
        linked: {
          'Sales Invoice': ['INV-1', 'INV-2'],
        },
      ),
    );
    await engine.runOnce();
    final row = await outbox.findById(1);
    expect(row!.state, OutboxState.failed);
    expect(row.errorCode, ErrorCode.LINK_EXISTS);
    expect(row.errorMessage, contains('INV-1'));
  });

  test('blocked rows are NOT dispatched', () async {
    await db.update(
      'outbox',
      {'state': 'blocked'},
      where: 'id=?',
      whereArgs: [1],
    );
    var called = false;
    final engine = buildEngine(
      send: (m, p, sn) async {
        called = true;
        return {'name': 'X', 'modified': '2026'};
      },
    );
    await engine.runOnce();
    expect(called, isFalse);
  });

  test('TimestampMismatch → auto-merge + retry once → succeeds', () async {
    // Slim outbox: server_name + push_base_payload live on docs__.
    // The outbox row only carries operation/state/created_at.
    await db.update(
      'docs__customer',
      {
        'server_name': 'CUST-1',
        'modified': '2026-01-01',
        'customer_name': 'LocalEdit',
        // Base snapshot: customer_name was 'ACME' when the user started
        // editing — captured by OfflineRepository.saveDocument and
        // consumed by PushEngine._autoMergeAndRetry.
        'push_base_payload': '{"customer_name":"ACME"}',
      },
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    await db.update(
      'outbox',
      {'operation': 'UPDATE'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );

    var sendCalls = 0;
    var fetchCalls = 0;
    final engine = buildEngine(
      send: (m, p, sn) async {
        sendCalls++;
        if (sendCalls == 1) {
          throw TimestampMismatchError(serverModified: '2026-01-02');
        }
        // After auto-merge, the second call sends the merged payload.
        // Local edit "LocalEdit" must have survived the merge (ours
        // diverged from base 'ACME'). Server change to 'description'
        // would also be present if we modeled it.
        expect(p['customer_name'], 'LocalEdit');
        return {'name': 'CUST-1', 'modified': '2026-01-03'};
      },
      serverFetcher: (doctype, name) async {
        fetchCalls++;
        // Server's current version: name unchanged since base, modified
        // advanced.
        return {
          'name': 'CUST-1',
          'modified': '2026-01-02',
          'customer_name': 'ACME',
        };
      },
    );
    await engine.runOnce();
    expect(sendCalls, 2, reason: 'one initial + one retry after merge');
    expect(fetchCalls, 1, reason: 'serverFetcher called once for refetch');
    // Slim outbox: markDone deletes the row outright.
    expect(await outbox.findById(1), isNull);
  });

  test(
    'TimestampMismatch with empty push_base_payload → markConflict (no auto-merge)',
    () async {
      // Regression for PR#36 review item #6 (claim 2). With an empty
      // base, three-way merge can't tell a "user-left-null" field from
      // a "user-explicitly-cleared" one, and would silently take server
      // values. Safer: surface to the user as conflict.
      await db.update(
        'docs__customer',
        {
          'server_name': 'CUST-1',
          'modified': '2026-01-01',
          'customer_name': 'LocalEdit',
          // push_base_payload deliberately NULL to simulate a legacy or
          // unmetafied save.
          'push_base_payload': null,
        },
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      await db.update(
        'outbox',
        {'operation': 'UPDATE'},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );

      var sendCalls = 0;
      var fetchCalls = 0;
      final engine = buildEngine(
        send: (m, p, sn) async {
          sendCalls++;
          throw TimestampMismatchError(serverModified: '2026-01-02');
        },
        serverFetcher: (doctype, name) async {
          fetchCalls++;
          return {
            'name': 'CUST-1',
            'modified': '2026-01-02',
            'customer_name': 'ServerEdit',
          };
        },
      );
      await engine.runOnce();
      expect(sendCalls, 1, reason: 'no auto-merge attempt with empty base');
      expect(fetchCalls, 0, reason: 'no server refetch with empty base');
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.conflict);
      expect(row.errorCode, ErrorCode.TIMESTAMP_MISMATCH);
    },
  );

  test(
    'TimestampMismatch persists across merge retry → markConflict (no unbounded recursion)',
    () async {
      // Regression for PR#36 review item #2. The merge-retry guard must
      // give up after one attempt and mark the row conflict; if the guard
      // is wrong, the engine recurses forever.
      await db.update(
        'docs__customer',
        {
          'server_name': 'CUST-1',
          'modified': '2026-01-01',
          'customer_name': 'LocalEdit',
          'push_base_payload': '{"customer_name":"ACME"}',
        },
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      await db.update(
        'outbox',
        {'operation': 'UPDATE'},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );

      var sendCalls = 0;
      final engine = buildEngine(
        send: (m, p, sn) async {
          sendCalls++;
          // Server keeps rejecting on every attempt.
          throw TimestampMismatchError(serverModified: '2026-01-0$sendCalls');
        },
        serverFetcher: (doctype, name) async {
          // Server keeps moving each time we refetch.
          return {
            'name': 'CUST-1',
            'modified': '2026-01-0$sendCalls',
            'customer_name': 'ServerEdit',
          };
        },
      );
      await engine.runOnce().timeout(const Duration(seconds: 5));
      // Engine must NOT recurse forever — at most two send attempts
      // (the original + one merge retry).
      expect(
        sendCalls,
        lessThanOrEqualTo(2),
        reason: 'merge guard must stop after one retry, not recurse',
      );
      final row = await outbox.findById(1);
      expect(row, isNotNull);
      expect(row!.state, OutboxState.conflict);
      expect(row.errorCode, ErrorCode.TIMESTAMP_MISMATCH);
    },
  );

  test(
    'L1 INSERT: DuplicateEntryError → fetch by mobile_uuid + write-back',
    () async {
      // Default test setup: autoname=field:mobile_uuid → L1.
      var sendCalls = 0;
      var fetchCalls = 0;
      String? fetchedName;
      final engine = buildEngine(
        send: (m, p, sn) async {
          sendCalls++;
          throw DuplicateEntryError();
        },
        serverFetcher: (doctype, name) async {
          fetchCalls++;
          fetchedName = name;
          return {
            'name': 'u-c-1',
            'modified': '2026-01-02 00:00:00',
            'customer_name': 'ACME',
          };
        },
      );
      await engine.runOnce();
      expect(sendCalls, 1);
      expect(fetchCalls, 1, reason: 'L1 fetches existing doc by mobile_uuid');
      expect(fetchedName, 'u-c-1');
      // Slim outbox: markDone deletes the row outright.
      expect(await outbox.findById(1), isNull);
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'u-c-1');
      expect(docRow['sync_status'], 'synced');
    },
  );

  test(
    'L2 INSERT: DuplicateEntryError(existingName) → fetch by name + write-back',
    () async {
      var fetchCalls = 0;
      String? fetchedName;
      final engine = buildEngine(
        // L2: server has dedup hook, no autoname.
        idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: true),
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: null,
          fields: [f('customer_name', 'Data')],
        ),
        send: (m, p, sn) async =>
            throw DuplicateEntryError(existingName: 'CUST-existing-7'),
        serverFetcher: (doctype, name) async {
          fetchCalls++;
          fetchedName = name;
          return {'name': 'CUST-existing-7', 'modified': '2026-01-02 00:00:00'};
        },
      );
      await engine.runOnce();
      expect(fetchCalls, 1);
      expect(fetchedName, 'CUST-existing-7');
      // Slim outbox: markDone deletes the row outright.
      expect(await outbox.findById(1), isNull);
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'CUST-existing-7');
    },
  );

  test(
    'L3 INSERT: pre-retry GET finds existing → adopt, no second send',
    () async {
      var sendCalls = 0;
      var lookupCalls = 0;
      String? lookupUuid;
      final engine = buildEngine(
        // L3: stock Frappe — no dedup hook, no autoname.
        idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: null,
          fields: [f('customer_name', 'Data')],
        ),
        send: (m, p, sn) async {
          sendCalls++;
          // First attempt fails network-class — server may or may not
          // have committed. The pre-retry GET below resolves the ambiguity.
          throw NetworkError(message: 'flaky');
        },
        serverLookupByUuid: (doctype, uuid) async {
          lookupCalls++;
          lookupUuid = uuid;
          return {
            'name': 'CUST-was-committed',
            'modified': '2026-01-02 00:00:00',
          };
        },
      );
      await engine.runOnce();
      expect(sendCalls, 1, reason: 'GET found row → no retry POST');
      expect(lookupCalls, 1);
      expect(lookupUuid, 'u-c-1');
      // Slim outbox: markDone deletes the row outright.
      expect(await outbox.findById(1), isNull);
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'CUST-was-committed');
    },
  );

  test('L3 INSERT: pre-retry GET finds nothing → continues retrying', () async {
    var sendCalls = 0;
    var lookupCalls = 0;
    final engine = buildEngine(
      idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
      customMeta: DocTypeMeta(
        name: 'Customer',
        autoname: null,
        fields: [f('customer_name', 'Data')],
      ),
      send: (m, p, sn) async {
        sendCalls++;
        throw NetworkError(message: 'flaky');
      },
      serverLookupByUuid: (doctype, uuid) async {
        lookupCalls++;
        return null; // server has nothing — original POSTs really failed
      },
    );
    await engine.runOnce();
    // 4 send attempts (1 initial + 3 retries given networkBackoff length 3).
    // Lookup runs once before each retry → 3 lookups.
    expect(sendCalls, 4);
    expect(lookupCalls, 3);
    final outRow = await outbox.findById(1);
    expect(outRow!.state, OutboxState.failed);
    expect(outRow.errorCode, ErrorCode.NETWORK);
  });

  test(
    'WriteQueue: response writeback routes through per-doctype queue',
    () async {
      final resolved = <String>[];
      final queues = <String, WriteQueue>{};
      final engine = buildEngine(
        send: (m, p, sn) async => {
          'name': 'CUST-1',
          'modified': '2026-01-01 00:00:00',
        },
        writeQueueResolver: (doctype) {
          resolved.add(doctype);
          return queues.putIfAbsent(
            doctype,
            () => WriteQueue(db: db, doctype: doctype),
          );
        },
      );
      await engine.runOnce();
      expect(resolved, [
        'Customer',
      ], reason: 'one queue resolved per parent doctype');
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'CUST-1');
      expect(docRow['sync_status'], 'synced');
      // Slim outbox: markDone deletes the row outright.
      expect(await outbox.findById(1), isNull);
    },
  );

  test(
    'tier ordering: dependent row dispatches AFTER its dependency',
    () async {
      // Add a second outbox row that depends on the first via a UUID-shaped
      // reference in its payload. Tier 1 (dependent) must dispatch after
      // tier 0 (the original row).
      await db.insert('docs__customer', {
        'mobile_uuid': 'b1c2d3e4-f5a6-4789-89ab-cdef01234567',
        'sync_status': 'dirty',
        'local_modified': 2,
        'customer_name': 'Dependent',
      });
      await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'b1c2d3e4-f5a6-4789-89ab-cdef01234567',
        operation: OutboxOperation.insert,
      );
      // Update the first outbox row to use a v4-shaped uuid so the scanner
      // can match the reference.
      await db.update(
        'docs__customer',
        {'mobile_uuid': 'a1b2c3d4-e5f6-4789-89ab-cdef01234567'},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      await db.update(
        'outbox',
        {'mobile_uuid': 'a1b2c3d4-e5f6-4789-89ab-cdef01234567'},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );

      final dispatchOrder = <String>[];
      final engine = buildEngine(
        send: (method, payload, serverName) async {
          dispatchOrder.add(payload['mobile_uuid'] as String);
          return {
            'name': 'SRV-${dispatchOrder.length}',
            'modified': '2026-01-0${dispatchOrder.length}',
          };
        },
      );
      await engine.runOnce();
      expect(dispatchOrder, [
        'a1b2c3d4-e5f6-4789-89ab-cdef01234567',
        'b1c2d3e4-f5a6-4789-89ab-cdef01234567',
      ]);
    },
  );

  test(
    'same-doctype INSERTs in one tier are serialized (max in-flight == 1) '
    'even with pool maxConcurrent=2 — prevents tabSeries deadlock storm',
    () async {
      // Two MORE Customer INSERTs (the seeded u-c-1 makes three). No deps →
      // all land in tier 0, all the same doctype → _dispatchUnits chains
      // them into ONE sequential unit. Pre-fix they were three separate
      // pool.submit calls and the pool (cap 2) ran two at once, racing on
      // the naming-series counter.
      for (final u in ['c-2', 'c-3']) {
        await db.insert('docs__customer', {
          'mobile_uuid': u,
          'sync_status': 'dirty',
          'local_modified': 1,
          'customer_name': 'C-$u',
        });
        await outbox.insertPending(
          doctype: 'Customer',
          mobileUuid: u,
          operation: OutboxOperation.insert,
        );
      }

      var inFlight = 0;
      var maxInFlight = 0;
      final engine = buildEngine(
        send: (method, payload, serverName) async {
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          inFlight--;
          return {
            'name': 'X-${payload['mobile_uuid']}',
            'modified': '2026-01-01',
          };
        },
      );
      await engine.runOnce();

      expect(
        maxInFlight,
        1,
        reason: 'same-doctype INSERTs must not overlap (pre-fix this was 2)',
      );
      // All three still synced.
      final synced = await db.query(
        'docs__customer',
        where: 'sync_status = ?',
        whereArgs: ['synced'],
      );
      expect(synced.length, 3);
    },
  );

  test('UUID Link WITHOUT __is_local flag: parent ordered first AND child '
      'payload gets resolved server_name (end-to-end no-flag fix)', () async {
    // Self-referential Link populated by a non-picker path → no
    // `parent_customer__is_local` companion. Before the fix the scanner
    // ignored it (no tier edge → race) and the rewriter passed the raw
    // UUID to the server.
    await db.execute(
      'ALTER TABLE docs__customer ADD COLUMN parent_customer TEXT',
    );
    const parentUuid = 'a1b2c3d4-e5f6-4789-89ab-cdef01234567';
    const childUuid = 'b1c2d3e4-f5a6-4789-89ab-cdef01234567';
    // Rename the seeded row to be the parent.
    await db.update(
      'docs__customer',
      {'mobile_uuid': parentUuid},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    await db.update(
      'outbox',
      {'mobile_uuid': parentUuid},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    // Child references the parent by UUID — and crucially NO
    // parent_customer__is_local column value.
    await db.insert('docs__customer', {
      'mobile_uuid': childUuid,
      'sync_status': 'dirty',
      'local_modified': 2,
      'customer_name': 'Child',
      'parent_customer': parentUuid,
    });
    await outbox.insertPending(
      doctype: 'Customer',
      mobileUuid: childUuid,
      operation: OutboxOperation.insert,
    );

    final dispatchOrder = <String>[];
    final sentParentCustomer = <String, Object?>{};
    final engine = buildEngine(
      customMeta: DocTypeMeta(
        name: 'Customer',
        autoname: 'field:mobile_uuid',
        fields: [
          f('customer_name', 'Data'),
          f('parent_customer', 'Link', options: 'Customer'),
        ],
      ),
      send: (method, payload, serverName) async {
        final uuid = payload['mobile_uuid'] as String;
        dispatchOrder.add(uuid);
        sentParentCustomer[uuid] = payload['parent_customer'];
        return {
          'name': 'SRV-${dispatchOrder.length}',
          'modified': '2026-01-0${dispatchOrder.length}',
        };
      },
    );
    await engine.runOnce();

    // Ordering: parent before child (scanner saw the UUID edge).
    expect(dispatchOrder, [parentUuid, childUuid]);
    // Rewrite: child's Link carries the parent's resolved server_name,
    // never the raw UUID.
    expect(sentParentCustomer[childUuid], 'SRV-1');
    expect(sentParentCustomer[childUuid], isNot(parentUuid));
  });

  test('onDrainComplete fires once after a drain', () async {
    var fired = 0;
    final engine = buildEngine(
      send: (m, p, sn) async => {
        'name': 'CUST-1',
        'modified': '2026-01-01 00:00:00',
      },
      onDrainComplete: () async => fired++,
    );
    await engine.runOnce();
    expect(fired, 1);
  });

  test('a throwing onDrainComplete does not escape runOnce', () async {
    final engine = buildEngine(
      send: (m, p, sn) async => {
        'name': 'CUST-1',
        'modified': '2026-01-01 00:00:00',
      },
      onDrainComplete: () async => throw StateError('boom'),
    );
    await engine.runOnce(); // must not throw
  });
}
