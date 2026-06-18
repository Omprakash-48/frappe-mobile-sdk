# Outbox State Machine

The outbox is a SQLite table (`outbox`) that tracks every write operation owed to the server. Each row represents one operation (INSERT / UPDATE / DELETE / SUBMIT / CANCEL) for one document. This document describes the state machine governing outbox rows, the rules for each state transition, and the invariants the sync engine relies on.

---

## States

```
 ┌──────────┐    dispatch     ┌───────────┐
 │ pending  │────────────────▶│ in_flight │
 └──────────┘                 └───────────┘
      ▲                             │
      │ re-save                     │ result
      │ (collapse)                  ▼
      │                      ┌─────────────────────────────────┐
      │           ┌──────────│         outcome                 │
      │           │          └─────────────────────────────────┘
      │           │  success       failed    terminal   conflict  blocked
      │           │     │            │          │          │         │
      │           ▼     ▼            ▼          ▼          ▼         ▼
      │         done  failed       paused    conflict    blocked
      │ (deleted)       │                     │            │
      └─────────────────┴─────────────────────┘
         resetToPending / re-save collapses
```

| State | Wire name | Meaning |
|-------|-----------|---------|
| `pending` | `pending` | Queued, awaiting dispatch by `PushEngine._drainOnce` |
| `in_flight` | `in_flight` | Dispatched to the worker pool, awaiting HTTP response |
| `done` | _(row deleted)_ | Push succeeded; row is hard-deleted (not stored as `done`) |
| `failed` | `failed` | Transient error (network, timeout, 5xx). Auto-retried on next drain |
| `paused` | `paused` | Terminal server rejection — validation error, mandatory field missing, permission denied, or link constraint. **Never auto-retried**; requires a corrected re-save to resume |
| `conflict` | `conflict` | Server `modified` timestamp is strictly after local `modified` — indicates concurrent edit from another client |
| `blocked` | `blocked` | A dependency (parent document) has not yet synced; push must wait |

### Paused vs Failed

`failed` and `paused` both represent push errors, but have different auto-retry semantics:

| | `failed` | `paused` |
|--|---------|---------|
| Cause | Network error, timeout, 5xx | Server rejected the payload (4xx business logic) |
| Auto-retried | Yes (next drain) | No |
| Appears in errors screen | Yes | Yes (since commit `22b9314`) |
| Included in `retryAll()` | Yes | **No** — re-queuing an unchanged payload would re-fail |
| Resume path | Automatic on next drain | User re-saves with corrected data → `recordSave` collapses it back to `pending` |

---

## State transitions

### `pending` → `in_flight`

`PushEngine._drainOnce` reads all `pending` rows, groups them into tiers by dependency, and dispatches each tier. Before dispatch, `markInFlight(id)` is called. If the process crashes mid-dispatch, `resetInFlightToPending()` restores any orphaned `in_flight` rows at the next `_drainOnce` entry.

### `in_flight` → `done` (row deleted)

Successful server response. `markDone(id, serverName: ...)` hard-deletes the row. The server name is written back to the `docs__<doctype>` mirror in the same operation.

### `in_flight` → `failed`

Transient error. `markFailed(id, errorCode: ..., errorMessage: ...)` writes the state. The row re-enters the drain on the next `syncNow` or `retryAll`.

### `in_flight` → `paused`

Terminal rejection (HTTP 4xx with a known error code: `VALIDATION`, `MANDATORY_FIELDS_REQUIRED`, `PERMISSION_DENIED`, `LINK_EXISTS`). `markPaused(id, ...)` writes the state. The row is excluded from `_drainOnce` (which reads only `pending`) and excluded from `retryAll` (which skips `paused` rows after commit `22b9314`).

### `in_flight` → `conflict`

Pull-apply detected a concurrent edit: the server's `modified` timestamp is strictly newer than the local row's `modified`. `markConflict(id)` writes the state. Resolved via `SyncController.resolveConflict()`.

### `in_flight` → `blocked`

A Link field referencing a parent document that has not yet synced. `markBlocked(id, reason: ...)` writes the state. The drain retries blocked rows when their dependencies clear.

### Any → `pending` (re-save collapse)

When the user saves a document, `OutboxDao.recordSave` runs inside a transaction. It finds existing rows in the _collapsable_ states (`pending`, `failed`, `blocked`, `conflict`, **`paused``) for the same `(doctype, mobile_uuid, operation)` tuple and resets the best candidate to `pending` via `resetToPending`. This is the **only** way a `paused` row re-enters the drain — through a corrected re-save.

---

## Supersede pass

At the start of every `_drainOnce`, a SQL `DELETE` removes older rows that have been made redundant by a newer `pending` row covering the same `(doctype, mobile_uuid, operation)` tuple:

```sql
DELETE FROM outbox
 WHERE id IN (
   SELECT older.id
     FROM outbox older
     JOIN outbox newer
       ON older.doctype     = newer.doctype
      AND older.mobile_uuid = newer.mobile_uuid
      AND older.operation   = newer.operation
      AND older.state       IN ('failed', 'paused')   -- ← both, since commit 22b9314
      AND newer.state       = 'pending'
      AND older.created_at  < newer.created_at
 )
```

**Why `paused` must be included:** Before this fix (supersede only matched `failed`), the following scenario produced a phantom error:

1. Row A (INSERT) dispatches, gets a terminal rejection → `paused`.
2. User corrects data and re-saves → `recordSave` resets A to `pending`. Now Row A is `pending`.
3. A dispatches again before the write-back → marks A as `in_flight`. User re-saves again → new Row B inserted (`pending`), since `in_flight` is not collapsable.
4. A completes successfully. Write-back runs. Now Row B is `pending`.
5. Without the fix: the supersede pass would not clean up a stale `paused` row (from a third re-save cycle) → phantom error in the UI.

With `paused` included, stale superseded rows are always cleaned up when a newer `pending` row covers the same operation.

---

## `isOwnInsertRoundtrip` guard

During pull-apply, when a server document is matched via `mobile_uuid` fallback (because `server_name` is still NULL locally — i.e. the push INSERT committed server-side but the write-back hasn't run yet), the pull sets `isOwnInsertRoundtrip = true` and skips the conflict check to avoid a spurious conflict for our own data echoing back.

### Ghost-success data-loss scenario

This flag is unsafe when the user re-edited the document between the ghost-success push and the pull:

1. Row A (INSERT) pushes → server commits, but write-back fails → `server_name` stays NULL locally.
2. Row A is marked `failed`. The user re-edits the document → `docs__*` row is now **dirty** with new values. Row B (INSERT) is inserted as `pending`.
3. `syncNow` runs pull-first. `hasActivePushFor` only checked `pending` + `in_flight` — so Row A (failed) was invisible to the pull guard.
4. Pull returns the original committed values (without the user's new edits). `mobile_uuid` matches, `server_name` is NULL → `isOwnInsertRoundtrip = true` → dirty-conflict guard skipped → `docs__*` overwritten with the original server values. **User's new edits are lost.**

### Fix (commit `22b9314`)

After the `mobile_uuid` fallback match, the code now checks the outbox for any non-done, non-in_flight rows for the matched uuid before accepting `isOwnInsertRoundtrip`:

```dart
if (isOwnInsertRoundtrip && existing.isNotEmpty) {
  final mobileUuid = existing.first['mobile_uuid'] as String? ?? '';
  if (mobileUuid.isNotEmpty) {
    final pendingWork = await txn.rawQuery(
      "SELECT id FROM outbox WHERE mobile_uuid = ? AND state NOT IN ('done','in_flight') LIMIT 1",
      [mobileUuid],
    );
    if (pendingWork.isNotEmpty) {
      isOwnInsertRoundtrip = false;  // ← fall through to conflict guard
    }
  }
}
```

If owed work exists (failed, paused, conflict, blocked, pending), the flag is cleared and the conflict guard runs, which correctly defers the overwrite.

---

## `recordSave` duplicate-INSERT prevention

`recordSave` finds the best existing collapsable row via `firstWhere` and resets it to `pending`. Before commit `22b9314`, in the edge case where a paused + pending INSERT pair co-existed (from the ghost-success scenario above), `firstWhere` reset one row but left the other. Both rows then dispatched — producing two INSERTs for the same document.

The fix deletes all remaining collapsable same-operation rows after resetting the survivor:

```dart
// After resetToPending(existingInsert['id'])
await _db.delete(
  'outbox',
  where: 'doctype = ? AND mobile_uuid = ? AND operation = ? AND id != ? AND $collapsableStateInClause',
  whereArgs: [doctype, mobileUuid, 'INSERT', existingInsert['id'], ..._collapsableStateWireNames],
);
```

---

## Error surfacing

The following queries include `paused` rows (since commit `22b9314`):

| Query | Where used |
|-------|-----------|
| `SyncController._allActionableRows()` | `pendingErrors()` → SyncErrorsScreen, badges, home counts |
| `OfflineRepository.getSyncErrorsForDoc()` | Per-document sync banner in forms |

`retryAll()` explicitly **excludes** `paused` from the rows it resets to `pending`. Bulk-re-queuing a terminal rejection with an unchanged payload is incorrect — the server will reject it again. The resume path is: user corrects the data and re-saves, which calls `recordSave` and collapses the paused row back to pending.

---

## Invariants

1. **Only `pending` rows are dispatched.** `_drainOnce` reads `findByState(OutboxState.pending)` only.
2. **At most one pending row per `(doctype, mobile_uuid, operation)` tuple at any time.** Enforced by `recordSave` (collapse on re-save) and the supersede pass (delete stale failed/paused rows when a newer pending covers them).
3. **`paused` rows are never auto-retried.** They are visible in the error UI but excluded from `retryAll`. Per-row retry via `SyncController.retry(id)` is always available.
4. **`recordSave` runs inside a transaction.** The `assert(_db is Transaction)` guard in `recordSave` enforces this. The collapse-read and the insert/reset/delete are atomically consistent.
