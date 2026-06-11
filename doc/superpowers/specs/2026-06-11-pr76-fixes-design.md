# PR #76 Post-Review Fixes — Design Spec

**Date:** 2026-06-11  
**Branch:** `feat/sdk-offline-phase2`  
**Status:** Approved for implementation

---

## Overview

11 fixes across 6 categories identified during the thorough PR #76 review. One critical data-loss bug, two high-severity functional gaps, one debugPrint privacy issue, six CHANGELOG/doc factual errors, and one medium UX bug in the translation event stream.

---

## Fix 1 — C1: `_applyPageInTxnBulk` Fallback Gate (Critical)

### Problem

`applyPageInTxn` dispatches to `_applyPageInTxnBulk` whenever `isInitialSync = true` (`= !scratch.complete`). The bulk path executes `batch.insert(..., ConflictAlgorithm.replace)` unconditionally, bypassing three correctness guards present only in `_applyPageInTxnSequential`:

1. **Tombstone skip** — `sync_status == 'deleted'` rows are resurrected
2. **Dirty-row preservation** — `_locallyDirtyStatuses` rows are overwritten without conflict flagging
3. **Ghost-success guard** — rows with `server_name = null` but matching `mobile_uuid` create duplicate rows

`isInitialSync` is true on any resumed initial sync, not just first install. A user who edits a document while a large initial sync is underway, or whose device was killed mid-sync, can lose their unsaved work silently.

### Solution: Fallback Gate

In `applyPageInTxn`, before dispatching to the bulk path, run a single pre-check query. If any existing rows are in a dirty/deleted/ghost-success state, route the entire page through the sequential path.

**Location:** `lib/src/sync/pull_apply.dart` — `applyPageInTxn` method (currently lines 120–155)

```dart
// Collect incoming identifiers
final serverNames = rows
    .map((r) => r['name'] as String?)
    .where((n) => n != null && n.isNotEmpty)
    .cast<String>()
    .toList();
final incomingUuids = rows
    .map((r) => r['mobile_uuid']?.toString())
    .where((u) => u != null && u.isNotEmpty)
    .cast<String>()
    .toList();

if (isInitialSync && serverNames.isNotEmpty) {
  // Check for rows that need the sequential guards:
  // 1. Dirty/deleted by server_name match
  // 2. Ghost-success rows: mobile_uuid matches but server_name is null
  final dirtyStatuses = [..._locallyDirtyStatuses, 'deleted'];
  final snPlaceholders = List.filled(serverNames.length, '?').join(',');
  final dirtyPlaceholders = List.filled(dirtyStatuses.length, '?').join(',');

  String query;
  List<Object?> args;

  if (incomingUuids.isNotEmpty) {
    final uuidPlaceholders = List.filled(incomingUuids.length, '?').join(',');
    query = '''
      SELECT COUNT(*) AS n FROM $parentTable
      WHERE (server_name IN ($snPlaceholders) AND sync_status IN ($dirtyPlaceholders))
         OR (mobile_uuid IN ($uuidPlaceholders) AND (server_name IS NULL OR server_name = ''))
    ''';
    args = [...serverNames, ...dirtyStatuses, ...incomingUuids];
  } else {
    query = '''
      SELECT COUNT(*) AS n FROM $parentTable
      WHERE server_name IN ($snPlaceholders) AND sync_status IN ($dirtyPlaceholders)
    ''';
    args = [...serverNames, ...dirtyStatuses];
  }

  final result = await txn.rawQuery(query, args);
  final unsafeCount = (result.first['n'] as int? ?? 0);

  if (unsafeCount > 0) {
    sdkLog('PullApply.applyPageInTxn: $unsafeCount unsafe rows detected — falling back to sequential for $parentTable');
    return _applyPageInTxnSequential(
      txn: txn,
      parentMeta: parentMeta,
      parentTable: parentTable,
      childMetasByFieldname: childMetasByFieldname,
      rows: rows,
      uuidGen: uuidGen,
      parentNormFields: parentNormFields,
    );
  }
}
```

### Why This Is Safe

- The bulk path is only an **optimization** for the clean-slate initial sync case. Its sole purpose is to avoid per-row queries. When any row in the page requires a guard check, the sequential path is correct and its per-row cost is acceptable.
- The pre-check query is O(1) from SQLite's perspective (single COUNT with indexed columns).
- On a truly fresh install (no existing rows), the COUNT is always 0 and the bulk path always runs — no performance regression.

### New Tests

File: `test/sync/pull_apply_fallback_gate_test.dart`

| Test | Scenario | Expected |
|------|----------|----------|
| T1 | Dirty row (`sync_status='dirty'`) in table when initial sync runs | Sequential path chosen; dirty row preserved as conflict |
| T2 | Tombstoned row (`sync_status='deleted'`) when initial sync runs | Sequential path chosen; tombstone respected, row not resurrected |
| T3 | Ghost-success row (`mobile_uuid` matches, `server_name` null) when initial sync runs | Sequential path chosen; no duplicate row created |
| T4 | All-clean page (no existing rows, or all `sync_status='synced'`) | Bulk path chosen; no regression |

---

## Fix 2 — H1: `SyncError` with Real Document IDs

### Problem

When `applyServerPage` throws, the catch block in `sync_service.dart` creates a `SyncError` with `documentId: 'batch'` — an unactionable sentinel. The previous per-document path used the actual server name. Any consumer of `SyncError.documentId` (retry-by-document, error display) receives an unusable value.

### Solution

Extract server names from `batchRows` before calling `applyServerPage`. Use the first server name as `documentId` and include the count in `errorMessage` when the batch has more than one row.

**Location:** `lib/src/services/sync_service.dart` — `_pullOneInternal` method (around lines 541–560)

```dart
// Extract before the try block
final batchServerNames = batchRows
    .map((r) => r['name'] as String?)
    .whereType<String>()
    .toList();

// In catch:
errors.add(SyncError(
  documentId: batchServerNames.firstOrNull ?? 'unknown',
  doctype: doctype,
  operation: 'pull',
  errorMessage: batchServerNames.length > 1
      ? '$e (${batchServerNames.length} docs, first: ${batchServerNames.first})'
      : e.toString(),
));
```

No schema or model changes required. Backward-compatible — `documentId` is still a `String`.

---

## Fix 3 — H2: `retryPaused` for Stuck SUBMIT/CANCEL Rows

### Problem

`paused` SUBMIT/CANCEL outbox rows are permanently stuck:
- `retryAll()` explicitly filters them out (`r.state != OutboxState.paused`)
- `recordSave` collapse only works for SAVE operations
- No public API exists to reset them to `pending`

The comment in `sync_controller.dart` line 208 references "explicit retry" as the intended recovery path — it was never implemented.

### Solution

Add `retryPaused(int outboxId)` to `SyncController`:

**Location:** `lib/src/services/sync_controller.dart`

```dart
/// Resets a single paused row to [OutboxState.pending] and triggers a
/// push drain. Use this when a terminal server rejection has been
/// resolved (e.g. corrected permissions, re-enabled workflow rule) and
/// the user explicitly requests a retry.
///
/// For SAVE operations, prefer having the user re-save the corrected
/// document — [OutboxDao.recordSave] will collapse the paused row
/// automatically. This method is intended for SUBMIT and CANCEL rows
/// where no re-save mechanism exists.
Future<void> retryPaused(int outboxId) async {
  await outboxDao.resetToPending(outboxId);
  await runPush();
}
```

Expose on `FrappeSDK.sync` so host-app error screens can wire it to a "Retry" button on paused rows (paused rows are already surfaced via `pendingErrors()`).

**Also update `SyncController` doc comment** to mention `retryPaused` alongside `retry`, `retryAll`, `resolveConflict`.

---

## Fix 4 — H3: Replace `debugPrint` with `sdkLog` (26 calls)

### Problem

`sdkLog` is a no-op in release builds (`if (!kDebugMode) return`). `debugPrint` is not. 26 remaining `debugPrint` calls fire in production APKs/IPAs, leaking sync internals to device logs.

### Files and counts

| File | `debugPrint` calls to replace |
|------|-------------------------------|
| `lib/src/sdk/frappe_sdk.dart` | 18 |
| `lib/src/sync/push_engine.dart` | 3 |
| `lib/src/sync/pull_engine.dart` | 2 |
| `lib/src/database/app_database.dart` | 3 |

### Solution

Global `debugPrint(` → `sdkLog(` replacement in those 4 files. `sdkLog` is already imported and used in each file. No behavioral change in debug builds.

---

## Fix 5 — CHANGELOG + Docs Corrections (6 factual errors)

### H4 — Translation API claim

**File:** `CHANGELOG.md` — "Changed" section, PR #76 block  
**Error:** Claims `mobile_auth.get_translations` was replaced with `frappe.client.get_list`; claims "no custom backend required."  
**Fix:** Rewrite to: `mobile_auth.get_translations` is still used (required for compiled `.po` translations); `frappe.client.get_list('Translation')` was evaluated but not adopted (returns user-created translations only, misses field labels).

### H5 — TranslationDao architecture

**Files:** `CHANGELOG.md`, `doc/TRANSLATIONS.md` lines 29, 173, 224, 231  
**Error:** Describes `translations_cache.db` as a standalone file, independent of `AppDatabase`, wipeable without migration.  
**Fix:** Replace with: `kv` table inside `AppDatabase` (main database file); `TranslationDao.close()` is a no-op; cleared via `TranslationService.clearAll()` or `AppDatabase.clearAllData()`; `_migrateV3ToV4` was added precisely because this table requires a migration.

### H6 — Missing v3→v4 schema entry

**File:** `CHANGELOG.md` — Schema section  
**Error:** Still says version bumped 2→3, `schema_version = 3`.  
**Fix:** Add v3→v4 entry documenting: `kv` table added to `AppDatabase`, `_version` bumped from 3 to 4, `_migrateV3ToV4` runs automatically for all existing installs upgrading from v3.

### M2 — Non-existent `_openFuture` memoization

**File:** `CHANGELOG.md`  
**Error:** References `TranslationDao._openFuture` memoization (TOCTOU guard) — this field does not exist.  
**Fix:** Remove the entry. Replace with: the injected-`Database` constructor eliminates the lazy-open pattern; no TOCTOU risk exists.

### M3 — `onFfiInitFailure` undocumented

**Files:** `CHANGELOG.md`, `lib/src/sdk/frappe_sdk.dart` constructor  
**Fix:**  
- Add to CHANGELOG "Added" section with a short usage example (wire to Crashlytics non-fatal)  
- Add `/// Defaults to N. Increase for high-volume server datasets.` doc comments on page-size constructor params

---

## Fix 6 — M1: `_doRefresh` `onChanged` Suppression

### Problem

In `translation_service.dart`, `_doRefresh` updates `_cache[lang]` via `loadTranslations`, then if `bulkUpsert` throws, returns early without emitting `onChanged`. The in-memory cache is fresh but no subscriber is notified — `StreamBuilder`s and Riverpod stream providers display stale translations for the session.

### Solution

Move `_changedController.add(null)` outside the try/catch so it always fires after `_cache[lang]` is updated:

**Location:** `lib/src/services/translation_service.dart` — `_doRefresh` method

```dart
Future<void> _doRefresh(String lang) async {
  final map = await loadTranslations(lang); // populates _cache[lang]
  if (_disposed) return;
  if (map.isEmpty) return;
  try {
    await _dao?.bulkUpsert(lang, map);
  } catch (e, st) {
    sdkLog('TranslationService._doRefresh($lang) persist failed — $e\n$st');
    // fall through — in-memory cache is valid even if SQLite persistence failed
  }
  if (!_changedController.isClosed) _changedController.add(null);
}
```

### Test

Add to `test/translation_service_test.dart`:
- Mock `TranslationDao.bulkUpsert` to throw
- Verify `onChanged` stream still emits exactly once
- Verify `translate(lang, key)` returns the correct value (cache was updated)

---

## Implementation Order

1. **C1** — Fallback gate + 4 new tests (TDD: write tests first, verify red, implement gate, verify green)
2. **M1** — `_doRefresh` fix + 1 new test
3. **H1** — `SyncError` document IDs (surgical edit, no new test needed beyond existing error-path coverage)
4. **H2** — `retryPaused` + 1 new test
5. **H3** — `debugPrint` → `sdkLog` sweep (4 files, grep-replace)
6. **H4/H5/H6/M2/M3** — CHANGELOG + `doc/TRANSLATIONS.md` text corrections

---

## Acceptance Criteria

- [ ] All 1434 existing tests pass throughout
- [ ] 6 new tests added and passing (C1: 4, M1: 1, H2: 1)
- [ ] Zero `debugPrint` calls remain in `lib/src/` (verify with `grep -r debugPrint lib/src/`)
- [ ] `_applyPageInTxnBulk` is never reached when any existing row has `sync_status IN ('dirty','failed','conflict','blocked','deleted')` or is a ghost-success row
- [ ] `SyncError.documentId` is never the literal string `'batch'`
- [ ] `FrappeSDK.sync.retryPaused(id)` exists and resets the row to `pending`
- [ ] CHANGELOG no longer references `translations_cache.db`, `frappe.client.get_list` for translations, or `_openFuture`
- [ ] `doc/TRANSLATIONS.md` correctly describes `kv` as a table inside `AppDatabase`

---

## Files Changed

| File | Type of change |
|------|---------------|
| `lib/src/sync/pull_apply.dart` | Add fallback gate in `applyPageInTxn` |
| `lib/src/services/sync_service.dart` | Fix `SyncError.documentId` |
| `lib/src/services/sync_controller.dart` | Add `retryPaused` method |
| `lib/src/services/translation_service.dart` | Fix `_doRefresh` `onChanged` emit |
| `lib/src/sdk/frappe_sdk.dart` | `debugPrint` → `sdkLog` (18), expose `retryPaused`, doc `onFfiInitFailure` |
| `lib/src/sync/push_engine.dart` | `debugPrint` → `sdkLog` (3) |
| `lib/src/sync/pull_engine.dart` | `debugPrint` → `sdkLog` (2) |
| `lib/src/database/app_database.dart` | `debugPrint` → `sdkLog` (3) |
| `CHANGELOG.md` | Fix H4, H5, H6, M2, M3 |
| `doc/TRANSLATIONS.md` | Fix H5 (lines 29, 173, 224, 231) |
| `test/sync/pull_apply_fallback_gate_test.dart` | **New** — 4 tests for C1 |
| `test/translation_service_test.dart` | Add M1 bulkUpsert-failure test |
| `test/sync/sync_controller_retry_paused_test.dart` | **New** — H2 retryPaused test |
