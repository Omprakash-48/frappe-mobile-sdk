import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

typedef WriteTask<T> = Future<T> Function(Transaction txn);

/// Returns the [WriteQueue] for a given doctype. Engines that wire this
/// resolver build one queue per parent doctype on first use and route
/// every write through it so SQLite write contention is per-doctype-serial
/// across all pull/push activity, and consecutive writes amortise fsync
/// via the queue's batched-transaction behavior.
typedef WriteQueueResolver = WriteQueue Function(String doctype);

class _PendingWrite<T> {
  final WriteTask<T> task;
  final Completer<T> completer = Completer<T>();
  _PendingWrite(this.task);
}

/// A single task's outcome inside a batch, buffered until the outer
/// transaction resolves so completers are never resolved before COMMIT.
class _Outcome {
  final _PendingWrite<Object?> pending;
  final Object? result;
  final Object? error;
  final StackTrace? stackTrace;

  _Outcome.ok(this.pending, this.result) : error = null, stackTrace = null;
  _Outcome.err(this.pending, this.error, this.stackTrace) : result = null;

  bool get isError => error != null;
}

/// Per-doctype serial write queue. Submits run inside a single sqflite
/// `db.transaction(...)` block, with consecutive submits batched into the
/// same transaction up to [batchRows]. Different doctypes use independent
/// queues so they never block each other.
///
/// One transaction per batch — eliminates SQLite write contention while
/// keeping fsync amortised across writes. Per-task isolation is provided
/// by SQLite savepoints: a failed task is rolled back to its savepoint
/// (its partial writes are discarded) without aborting the outer
/// transaction or affecting sibling tasks.
class WriteQueue {
  final Database db;
  final String doctype;
  final int batchRows;

  final Queue<_PendingWrite<Object?>> _queue = Queue();
  bool _running = false;
  int _savepointCounter = 0;

  WriteQueue({required this.db, required this.doctype, this.batchRows = 50});

  Future<T> submit<T>(WriteTask<T> task) {
    final p = _PendingWrite<Object?>(
      (txn) async => (await task(txn)) as Object?,
    );
    _queue.add(p);
    _kick();
    return p.completer.future.then((v) => v as T);
  }

  void _kick() {
    if (_running) return;
    _running = true;
    Future<void>(() async {
      try {
        while (_queue.isNotEmpty) {
          // No Completer is resolved inside the transaction — neither
          // successes nor per-task failures. A task's writes are not durable
          // until the outer `db.transaction` COMMITs, and resolving mid-
          // transaction lets the caller's microtask advance (cursor moved,
          // outbox row marked done) before the data is durable; a subsequent
          // commit failure then loses the write with no observable error
          // (PR#36 round-4 B2). Per-task outcomes are collected here and
          // replayed in order only after the transaction resolves.
          final batch = <_Outcome>[];
          try {
            await db.transaction((txn) async {
              var count = 0;
              while (_queue.isNotEmpty && count < batchRows) {
                final p = _queue.removeFirst();
                final sp = 'wq_${++_savepointCounter}';
                try {
                  await txn.execute('SAVEPOINT $sp');
                  final r = await p.task(txn);
                  await txn.execute('RELEASE SAVEPOINT $sp');
                  batch.add(_Outcome.ok(p, r));
                } catch (e, st) {
                  // Roll back this task's partial writes; sibling tasks
                  // inside the same outer transaction are unaffected. The
                  // failure is recorded and reported after the transaction
                  // resolves, alongside the successes.
                  try {
                    await txn.execute('ROLLBACK TO SAVEPOINT $sp');
                    await txn.execute('RELEASE SAVEPOINT $sp');
                  } catch (rollbackErr, rollbackSt) {
                    // Savepoint may not exist if the SAVEPOINT itself failed.
                    debugPrint(
                      'WriteQueue: ROLLBACK TO SAVEPOINT $sp failed — $rollbackErr\n$rollbackSt',
                    );
                  }
                  batch.add(_Outcome.err(p, e, st));
                }
                count++;
              }
            });
            // COMMIT succeeded — the batch's writes are durable. Replay each
            // task's outcome now (outside the transaction).
            for (final o in batch) {
              if (o.isError) {
                o.pending.completer.completeError(o.error!, o.stackTrace);
              } else {
                o.pending.completer.complete(o.result);
              }
            }
          } catch (e, st) {
            // Outer `db.transaction` itself failed (e.g. database closed,
            // disk full, lock timeout) — nothing in this batch committed.
            // Tasks that failed their own savepoint still report their own
            // error; successful tasks whose writes were rolled back, and any
            // tasks still queued (which would otherwise hang on `submit()`),
            // get the outer failure so every caller observes it.
            debugPrint('WriteQueue: outer transaction failed — $e\n$st');
            for (final o in batch) {
              if (o.pending.completer.isCompleted) continue;
              if (o.isError) {
                o.pending.completer.completeError(o.error!, o.stackTrace);
              } else {
                o.pending.completer.completeError(e, st);
              }
            }
            while (_queue.isNotEmpty) {
              _queue.removeFirst().completer.completeError(e, st);
            }
          }
        }
      } finally {
        _running = false;
      }
    });
  }
}
