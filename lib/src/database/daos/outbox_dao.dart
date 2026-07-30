import 'package:sqflite/sqflite.dart';
import '../../models/outbox_row.dart';

/// Outcome of [OutboxDao.recordSave]. Lets the caller decide whether the
/// docs__ row should be tombstoned (`enqueued`) or hard-deleted
/// (`cancelledLocally` — the cancelled INSERT means the server never
/// knew about the doc, so there is nothing to push).
enum RecordSaveResult { enqueued, cancelledLocally }

/// The outbox states that can be collapsed into a newer save:
/// `pending`, `failed`, `blocked`, `conflict`, `paused`. `in_flight` and
/// `done` are deliberately excluded (a save during an in-flight push always
/// inserts a fresh follow-up row).
///
/// `paused` (#53) is collapsable so that a corrected re-save re-queues a row
/// the server had terminally rejected — that is the resume path out of pause.
final List<String> _collapsableStateWireNames = <String>[
  OutboxState.pending.wireName,
  OutboxState.failed.wireName,
  OutboxState.blocked.wireName,
  OutboxState.conflict.wireName,
  OutboxState.paused.wireName,
];

/// `state IN (?, ?, ...)` — one placeholder per collapsable state. Built from
/// [_collapsableStateWireNames] so the placeholder count can never drift from
/// the arg list when a state is added (e.g. `paused`).
final String _collapsableStateInClause =
    'state IN (${List.filled(_collapsableStateWireNames.length, '?').join(', ')})';

/// SQL WHERE clause that matches outbox rows in any collapsable state
/// for a given (doctype, mobileUuid). Used by [OutboxDao.recordSave]
/// (for both the collapse-candidate lookup and the DELETE-cancels-prior
/// branch) and [OutboxDao.cancelPendingFor]. Placeholders after `state IN`
/// are filled from [_collapsableStateWireNames].
final String _collapsableWhereClause =
    'doctype = ? AND mobile_uuid = ? AND $_collapsableStateInClause';

/// Builds the whereArgs list to go with [_collapsableWhereClause]:
/// `[doctype, mobileUuid, pending, failed, blocked, conflict, paused]`.
List<Object?> _collapsableWhereArgs(String doctype, String mobileUuid) =>
    <Object?>[doctype, mobileUuid, ..._collapsableStateWireNames];

class OutboxDao {
  final DatabaseExecutor _db;

  OutboxDao(this._db);

  /// Inserts a fresh pending outbox row. Used by tests, by L3 retry seam,
  /// and indirectly by [recordSave] when no collapse target exists.
  Future<int> insertPending({
    required String doctype,
    required String mobileUuid,
    required OutboxOperation operation,
    DateTime? createdAt,
  }) async {
    final ts = (createdAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return _db.insert('outbox', <String, Object?>{
      'doctype': doctype,
      'mobile_uuid': mobileUuid,
      'operation': operation.wireName,
      'state': OutboxState.pending.wireName,
      'created_at': ts,
    });
  }

  /// Records a save against the outbox.
  ///
  /// Only collapses against rows in `pending`, `failed`, `blocked`,
  /// `conflict`, `paused` (the "collapsable" buckets). `in_flight` and
  /// `done` are never touched — a save during an in-flight push always
  /// inserts a fresh follow-up row.
  Future<RecordSaveResult> recordSave({
    required String doctype,
    required String mobileUuid,
    required OutboxOperation operation,
    DateTime? createdAt,
  }) async {
    // recordSave reads existing outbox rows and conditionally writes
    // INSERT/DELETE updates. The collapse rules only hold if the read
    // and the writes are in the same transaction — otherwise a
    // concurrent push or save could interleave between the SELECT and
    // the DELETE/INSERT and corrupt the "no two pending rows per uuid"
    // invariant. Debug-only assert (PR#36 round-2 M6); production
    // callers all wrap in `db.transaction` today.
    assert(
      _db is Transaction,
      'OutboxDao.recordSave must be called via a Transaction. '
      'Wrap the call site in `db.transaction((txn) async { ... })` '
      'and pass `OutboxDao(txn)`.',
    );
    final stampedAt = createdAt ?? DateTime.now().toUtc();
    final existing = await _db.query(
      'outbox',
      where: _collapsableWhereClause,
      whereArgs: _collapsableWhereArgs(doctype, mobileUuid),
      orderBy: 'created_at ASC, id ASC',
    );

    if (operation == OutboxOperation.delete) {
      // DELETE collision rules: cancel any pending INSERT (with no
      // residual DELETE row), otherwise cancel UPDATEs and enqueue DELETE.
      final hasInsert = existing.any((r) => r['operation'] == 'INSERT');
      if (hasInsert) {
        await _db.delete(
          'outbox',
          where: _collapsableWhereClause,
          whereArgs: _collapsableWhereArgs(doctype, mobileUuid),
        );
        return RecordSaveResult.cancelledLocally;
      }
      await _db.delete(
        'outbox',
        where:
            'doctype = ? AND mobile_uuid = ? AND operation = ? '
            'AND $_collapsableStateInClause',
        whereArgs: [
          doctype,
          mobileUuid,
          'UPDATE',
          ..._collapsableStateWireNames,
        ],
      );
      await insertPending(
        doctype: doctype,
        mobileUuid: mobileUuid,
        operation: operation,
        createdAt: stampedAt,
      );
      return RecordSaveResult.enqueued;
    }

    if (operation == OutboxOperation.submit ||
        operation == OutboxOperation.cancel) {
      // SUBMIT/CANCEL never collapse — they're docstatus transitions
      // distinct from prior INSERT/UPDATE rows.
      await insertPending(
        doctype: doctype,
        mobileUuid: mobileUuid,
        operation: operation,
        createdAt: stampedAt,
      );
      return RecordSaveResult.enqueued;
    }

    // INSERT or UPDATE.
    final existingInsert = existing.firstWhere(
      (r) => r['operation'] == 'INSERT',
      orElse: () => const <String, Object?>{},
    );
    if (existingInsert.isNotEmpty) {
      await resetToPending(existingInsert['id'] as int);
      // Delete any redundant collapsable INSERT rows (e.g. a paused row
      // that co-exists with the pending one after the supersede pass
      // didn't clean it up). Without this, two pending INSERTs can pile
      // up for the same document.
      await _db.delete(
        'outbox',
        where:
            'doctype = ? AND mobile_uuid = ? AND operation = ? AND id != ? '
            'AND $_collapsableStateInClause',
        whereArgs: [
          doctype,
          mobileUuid,
          'INSERT',
          existingInsert['id'],
          ..._collapsableStateWireNames,
        ],
      );
      return RecordSaveResult.enqueued;
    }
    final existingUpdate = existing.firstWhere(
      (r) => r['operation'] == 'UPDATE',
      orElse: () => const <String, Object?>{},
    );
    if (existingUpdate.isNotEmpty) {
      await resetToPending(existingUpdate['id'] as int);
      // Delete any redundant collapsable UPDATE rows for the same tuple.
      await _db.delete(
        'outbox',
        where:
            'doctype = ? AND mobile_uuid = ? AND operation = ? AND id != ? '
            'AND $_collapsableStateInClause',
        whereArgs: [
          doctype,
          mobileUuid,
          'UPDATE',
          existingUpdate['id'],
          ..._collapsableStateWireNames,
        ],
      );
      return RecordSaveResult.enqueued;
    }
    await insertPending(
      doctype: doctype,
      mobileUuid: mobileUuid,
      operation: operation,
      createdAt: stampedAt,
    );
    return RecordSaveResult.enqueued;
  }

  /// Cancels every collapsable (non-in_flight, non-done) outbox row for
  /// this uuid. Used by [OfflineRepository.deleteDocument] when the
  /// caller wants to clear queued work explicitly.
  Future<void> cancelPendingFor({
    required String doctype,
    required String mobileUuid,
  }) async {
    await _db.delete(
      'outbox',
      where: _collapsableWhereClause,
      whereArgs: _collapsableWhereArgs(doctype, mobileUuid),
    );
  }

  Future<OutboxRow?> findById(int id) async {
    final rows = await _db.query(
      'outbox',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return OutboxRow.fromMap(rows.first);
  }

  /// Every outbox row queued for `(doctype, mobileUuid)` regardless of
  /// state, ordered oldest-first. Callers typically filter to non-`done`
  /// rows for UI surfacing.
  Future<List<OutboxRow>> findByMobileUuid({
    required String doctype,
    required String mobileUuid,
  }) async {
    final rows = await _db.query(
      'outbox',
      where: 'doctype = ? AND mobile_uuid = ?',
      whereArgs: [doctype, mobileUuid],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(OutboxRow.fromMap).toList();
  }

  Future<List<OutboxRow>> findByState(OutboxState state) async {
    final rows = await _db.query(
      'outbox',
      where: 'state = ?',
      whereArgs: [state.wireName],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(OutboxRow.fromMap).toList();
  }

  Future<void> markInFlight(int id) async {
    await _db.update(
      'outbox',
      <String, Object?>{'state': OutboxState.inFlight.wireName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Removes the outbox row outright. After a successful `_writeBack`,
  /// the operation is owed to nothing — keeping a `done` row would
  /// violate the "outbox holds only owed-to-server work" invariant.
  Future<void> markDone(int id, {required String serverName}) async {
    await _db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markFailed(
    int id, {
    required ErrorCode errorCode,
    required String errorMessage,
  }) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.failed.wireName,
        'error_code': errorCode.wireName,
        'error_message': errorMessage,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Parks a row out of the auto-retry loop after a terminal server rejection
  /// (#53). Distinct from [markFailed]: the push drain reads only `pending`,
  /// so a `paused` row is never auto-retried. It re-enters `pending` when the
  /// user re-saves the record ([recordSave] collapses it) or explicitly via
  /// [resetToPending].
  Future<void> markPaused(
    int id, {
    required ErrorCode errorCode,
    required String errorMessage,
  }) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.paused.wireName,
        'error_code': errorCode.wireName,
        'error_message': errorMessage,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markConflict(int id, {String? errorMessage}) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.conflict.wireName,
        'error_code': ErrorCode.TIMESTAMP_MISMATCH.wireName,
        'error_message': errorMessage,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markBlocked(int id, {required String reason}) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.blocked.wireName,
        'error_message': reason,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<Map<OutboxState, int>> countByState() async {
    final rows = await _db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM outbox GROUP BY state',
    );
    final out = <OutboxState, int>{};
    for (final r in rows) {
      out[OutboxStateHelpers.parse(r['state'] as String)] = r['n'] as int;
    }
    return out;
  }

  Future<int> resetInFlightToPending() async {
    return _db.update(
      'outbox',
      <String, Object?>{'state': OutboxState.pending.wireName},
      where: 'state = ?',
      whereArgs: [OutboxState.inFlight.wireName],
    );
  }

  /// Flips a row in any non-pending state back to `pending` so the push
  /// engine picks it up on the next drain. Clears `error_code` /
  /// `error_message` so retries start with a fresh slate. Used by
  /// `SyncController.retry` / `retryAll` and the conflict-resolution
  /// flow's "keep local + retry" branch.
  Future<void> resetToPending(int id) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.pending.wireName,
        'error_code': null,
        'error_message': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> hasActivePushFor(String doctype) async {
    final rows = await _db.rawQuery(
      '''SELECT 1 FROM outbox
         WHERE doctype = ? AND state IN (?, ?)
         LIMIT 1''',
      [doctype, OutboxState.pending.wireName, OutboxState.inFlight.wireName],
    );
    return rows.isNotEmpty;
  }
}
