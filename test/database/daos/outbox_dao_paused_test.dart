// #53 (A5): OutboxDao behavior for the `paused` state.
//  - markPaused parks a terminally-rejected row (state=paused + code + msg).
//  - the push drain (findByState pending) never picks up a paused row.
//  - a paused row does NOT count as an active push (so it can't block pulls).
//  - re-saving the record collapses/reset the paused row back to pending
//    (the resume path — user fixed the data).
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
    dao = OutboxDao(db);
  });

  tearDown(() async => db.close());

  test('markPaused parks the row with code + message', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    await dao.markPaused(
      id,
      errorCode: ErrorCode.VALIDATION,
      errorMessage: 'Age must be > 0',
    );
    final row = await dao.findById(id);
    expect(row!.state, OutboxState.paused);
    expect(row.errorCode, ErrorCode.VALIDATION);
    expect(row.errorMessage, 'Age must be > 0');
    expect(row.isTerminal, isTrue);
  });

  test('paused rows are excluded from the pending drain', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    await dao.markPaused(
      id,
      errorCode: ErrorCode.VALIDATION,
      errorMessage: 'bad',
    );
    final pending = await dao.findByState(OutboxState.pending);
    expect(
      pending,
      isEmpty,
      reason: 'a paused row must never be auto-retried by the drain',
    );
  });

  test(
    'a paused row does not count as an active push (cannot block pulls)',
    () async {
      final id = await dao.insertPending(
        doctype: 'X',
        mobileUuid: 'u1',
        operation: OutboxOperation.insert,
      );
      await dao.markPaused(
        id,
        errorCode: ErrorCode.VALIDATION,
        errorMessage: 'bad',
      );
      expect(await dao.hasActivePushFor('X'), isFalse);
    },
  );

  test(
    're-saving the record resets the paused row to pending (resume)',
    () async {
      final id = await dao.insertPending(
        doctype: 'X',
        mobileUuid: 'u1',
        operation: OutboxOperation.insert,
      );
      await dao.markPaused(
        id,
        errorCode: ErrorCode.VALIDATION,
        errorMessage: 'bad',
      );

      // User edits + saves again → same (doctype, uuid), INSERT.
      // recordSave must run in a transaction (collapse invariant).
      final result = await db.transaction(
        (txn) => OutboxDao(txn).recordSave(
          doctype: 'X',
          mobileUuid: 'u1',
          operation: OutboxOperation.insert,
        ),
      );

      expect(result, RecordSaveResult.enqueued);
      final row = await dao.findById(id);
      expect(
        row!.state,
        OutboxState.pending,
        reason: 'a corrected re-save must re-queue the paused row',
      );
      expect(row.errorCode, isNull);
      expect(row.errorMessage, isNull);
    },
  );
}
