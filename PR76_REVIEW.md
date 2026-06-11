# PR #76 Review — `feat/sdk-offline-phase2`

**Reviewed HEAD:** `a8901f6d6ca35fdc8bfa78b22fbd8e7f99a5ce80`  
**Review Date:** 2026-06-11  
**Reviewed By:** Claude Code (5-agent parallel review: API surface/lifecycle, runtime bugs, git regression analysis, prior-PR comment carry-over, DX/docs compliance)  
**Methodology:** Each issue independently scored 0–100 for confidence. Only issues scoring ≥ 80 are included.

---

## Summary

PR #76 delivers a substantial batch of offline-first improvements: SQLite FFI migration, batch pull operations, translation persistence, `TranslationDao` consolidation, `LinkDecorator` batching, and 14 targeted bug fixes from prior reviews. The infrastructure is well-tested (1434 tests, all passing) and most of the prior-review feedback has been addressed.

**One critical production bug was introduced** by the new `_applyPageInTxnBulk` path. It is blocked on that. The remaining issues are a mix of high-severity bugs and documentation that actively contradicts the implementation — both correctable before merge.

---

## Issues by Severity

### CRITICAL

---

#### C1 — `_applyPageInTxnBulk` bypasses all safety guards from the sequential path

**File:** `lib/src/sync/pull_apply.dart` — `_applyPageInTxnBulk`  
**Confidence:** 100 — confirmed independently by all four code-reading agents; verified against the commit history that added these guards.

The PR introduces two pull paths gated by `isInitialSync` (`= !scratch.complete`). On any initial sync — including resumes after a crash or a `forcePullAll` — the new bulk path runs. It executes `batch.insert(..., ConflictAlgorithm.replace)` unconditionally for every row. It replicates **none** of the three correctness guards present in `_applyPageInTxnSequential`:

**Guard 1 — Tombstone skip (absent from bulk path):**
```dart
// SEQUENTIAL only — bulk path has no sync_status check at all:
if (existing.isNotEmpty && existing.first['sync_status'] == 'deleted') {
  continue; // local DELETE queued in outbox; don't resurrect
}
```
A user who deletes a document offline (outbox DELETE queued) will see the record reappear in the list the next time a bulk-path sync runs, because `ConflictAlgorithm.replace` overwrites the tombstone with the server's copy. The pending outbox DELETE eventually fires, but the user experiences a confusing resurrection.

**Guard 2 — Dirty/conflict skip (absent from bulk path):**
```dart
// SEQUENTIAL only — bulk path stamps sync_status:'synced' unconditionally:
if (existing.isNotEmpty &&
    !isOwnInsertRoundtrip &&
    _locallyDirtyStatuses.contains(existing.first['sync_status'])) {
  // mark conflict or skip
}
```
A document the user edited while offline (`sync_status = 'dirty'`, `'conflict'`, or `'blocked'`) is silently overwritten with the server's version. No conflict record is created. The user's unsynced edits are destroyed with no indication.

**Guard 3 — `mobile_uuid` fallback lookup (absent from bulk path):**
The sequential path has a second query that matches by `mobile_uuid` when `server_name = NULL` — the round-trip path for a push INSERT whose response-writeback hasn't landed yet (fix for issue #43, present in this PR on the sequential path). The bulk path only queries by `server_name IN (...)`. A row without a `server_name` is missed; `uuidGen.v4()` creates a fresh UUID; `ConflictAlgorithm.replace` inserts a new row. The original offline-origin row (with the correct `mobile_uuid`) remains in the table with `server_name = null`. Duplicate rows are created silently.

**When this is reachable:**  
`isInitialSync = !scratch.complete`. This is `true` not just on first install — it is `true` on any resume after a crash mid-initial-sync, and on any doctype that hasn't completed its first full pull. `FormScreen.canSave` is not gated on initial sync completion. Any user who creates or edits a document during a large initial sync is in this scenario.

**Required fix:** Before each `batch.insert` in `_applyPageInTxnBulk`, pre-query existing rows for `sync_status` and `mobile_uuid`. Skip rows with `sync_status == 'deleted'`. Fall through to the sequential path (or flag conflict) for rows in `_locallyDirtyStatuses`. Add the `mobile_uuid` fallback lookup. Alternatively, gate the bulk path on `_locallyDirtyStatuses` being empty for the entire page — the optimization is only safe on a clean slate.

---

**C1b — Child-UUID preservation also absent from bulk path**

**File:** `lib/src/sync/pull_apply.dart` — `_applyPageInTxnBulk` child-insertion loop  
**Confidence:** 85

The sequential path snapshots existing child UUIDs before the transaction, builds `byServerName`/`byPosition` maps, and uses them to keep stable `mobile_uuid` values across re-pulls. Any host-app field or pending attachment that references a child row's `mobile_uuid` (for parent–child linking) will silently receive a new, unrelated UUID on the next resumed-initial-sync pass because the bulk path does:

```dart
final childUuid = hasRawUuid ? rawChildUuid : uuidGen.v4();
```

There is no snapshot, no map lookup, and no fallback to the previously-stored UUID. Any cross-child `Link` field or `pending_attachments.parent_uuid` pointing at the original UUID will be orphaned after the first bulk re-apply.

---

### HIGH

---

#### H1 — `SyncError.documentId` is the literal string `'batch'` when a page apply fails

**File:** `lib/src/services/sync_service.dart` — `_pullOneInternal` error handler  
**Confidence:** 90

The per-page refactor reports a single `SyncError` on failure:

```dart
errors.add(SyncError(
  documentId: 'batch',   // ← literal sentinel, not a document ID
  doctype: doctype,
  operation: 'pull',
  errorMessage: e.toString(),
));
```

The old per-document path used `documentId: serverId` — the actual server name. Any consumer of `SyncError.documentId` (retry-by-document, conflict resolution, error display) receives `'batch'` instead of an actionable identifier. `batchRows.length` is logged to `sdkLog` but not persisted.

**Fix:** Store the affected document IDs before the batch runs, then report them individually (or as a comma-separated list) on failure. At minimum replace `'batch'` with the list of `server_name` values in `batchRows`.

---

#### H2 — `paused` SUBMIT/CANCEL rows are permanently stuck with no recovery path

**File:** `lib/src/sync/push_engine.dart`, `lib/src/database/daos/outbox_dao.dart`, `lib/src/sync/sync_controller.dart`  
**Confidence:** 85

`retryAll()` explicitly filters out paused rows:
```dart
.where((r) => r.state != OutboxState.paused)
```

`recordSave` for SUBMIT/CANCEL does not collapse to a new pending row (collapse only applies to INSERT). `cancelPendingFor` hard-deletes paused rows — but cancelling a submission without confirmation is a business-logic decision that cannot be the silent recovery path. There is no UI affordance to manually un-pause a SUBMIT/CANCEL row and no programmatic API.

Result: a document whose SUBMIT was PERMISSION_DENIED (or any other terminal error code) is permanently stuck. The user sees it in `pendingErrors()` but has no way to retry it. The document cannot be submitted again without direct SQLite manipulation.

**Fix:** Expose a `retryPaused(documentId)` method that resets a paused SUBMIT/CANCEL to `pending`, gated on explicit user intent. Or document the intended recovery flow explicitly if manual cancellation is acceptable.

---

#### H3 — 20+ `debugPrint` calls remain in production-compiled code; CHANGELOG claims migration is complete

**Files:** `lib/src/sdk/frappe_sdk.dart` (~15 calls), `lib/src/sync/push_engine.dart` (~3), `lib/src/sync/pull_engine.dart` (~2), `lib/src/database/app_database.dart` (~3)  
**Confidence:** 90

`sdkLog` is guarded by `if (!kDebugMode) return` — it is a no-op in release builds. `debugPrint` is not. Every remaining `debugPrint` call fires in production APKs and IPAs, producing logs visible via `adb logcat` or Xcode's device console containing sync internals, server error messages, and document payload fragments.

The CHANGELOG states: _"debugPrint → sdkLog migration completed across translation_service.dart, doctype_service.dart, login_screen.dart, sync_status_screen.dart, form_screen.dart, document_list_screen.dart, and app_guard.dart."_ This is accurate for those files only. The migration is not complete in the files listed above.

In a health-data app handling beneficiary records, logging document content and sync state to the unguarded device log in production builds is a privacy concern.

**Fix:** Replace all remaining `debugPrint` calls in the above files with `sdkLog`.

---

#### H4 — CHANGELOG incorrectly states that `loadTranslations` was migrated from `mobile_auth.get_translations` to `frappe.client.get_list`

**File:** `CHANGELOG.md` — "Changed" block for PR #76  
**Confidence:** 100

CHANGELOG:
> `TranslationService.loadTranslations` — migrated from `mobile_auth.get_translations` to `frappe.client.get_list` on the standard `Translation` doctype. **No custom backend method required; works with any Frappe installation.**

Actual source at HEAD (`lib/src/services/translation_service.dart`):
```dart
'/api/v2/method/mobile_auth.get_translations'
```

`frappe.client.get_list` appears only in `fetchEnabledLanguages` (Language doctype), not translations. The inline code comment in `translation_service.dart` explicitly explains why `get_list('Translation')` is not used: it returns only user-created custom translations, not the compiled `.po` translations that supply field labels.

An integrator reading the CHANGELOG will deploy to a stock Frappe installation without `frappe-mobile-control` and receive 404s on every translation load — with no visible error message and no translations displayed. The claim "no custom backend required" is actively incorrect.

**Fix:** Correct the CHANGELOG entry to state that `mobile_auth.get_translations` is still required. Align with `doc/TRANSLATIONS.md` (which correctly describes the API at line ~85).

---

#### H5 — CHANGELOG and `doc/TRANSLATIONS.md` describe `TranslationDao` as a standalone `translations_cache.db` file; it lives inside `AppDatabase`

**Files:** `CHANGELOG.md`, `doc/TRANSLATIONS.md` lines 29, 173, 224, 231  
**Confidence:** 100

CHANGELOG: _"`TranslationDao` — standalone KV SQLite store (`translations_cache.db`). **Fully independent of `AppDatabase`; can be wiped without a migration.**"_

`doc/TRANSLATIONS.md` line 173: _"completely separate from the main `AppDatabase`"_

Actual implementation:
- `TranslationDao` is constructed as `TranslationDao(database.rawDatabase)` — same handle as `AppDatabase`
- The `kv` table lives in `<appname>_frappe.db` (the main database) — there is no `translations_cache.db`
- `TranslationDao.close()` is an intentional no-op (doc comment: "Let AppDatabase manage connection lifecycle")
- PR #76 adds `_migrateV3ToV4` and bumps `_version` from 3→4 precisely to create `kv` inside the main DB
- "Can be wiped without a migration" is the direct inverse of the truth

Three separate claims in the changelog are wrong. Consumers will attempt to delete a file that doesn't exist, build integrations that treat the translation cache as a separate resource, and may have incorrect assumptions about backup/restore behavior.

**Fix:** Replace all references to `translations_cache.db` and "fully independent" with the correct architecture: `kv` table in `AppDatabase`, managed by the same lifecycle, cleared via `TranslationService.clearAll()` or `AppDatabase.clearAllData()`.

---

#### H6 — CHANGELOG omits the v3→v4 schema migration entirely

**File:** `CHANGELOG.md` — "Schema" section  
**Confidence:** 100

The CHANGELOG `Schema` section still says:
> `AppDatabase._version` bumped from `2` to `3`. `schema_version = 3`.

PR #76 bumps `_version` to `4` and adds `_migrateV3ToV4`. Any consumer who pins a build, forks the migration chain, or writes an integration test against the schema version will have a silent gap. The `schema_version = 3` claim is wrong by one version.

**Fix:** Add a `v3 → v4` entry to the CHANGELOG Schema section documenting: `kv` table added to `AppDatabase`, `TranslationDao` consolidated from standalone to shared DB, `_version` bumped to `4`, `_migrateV3ToV4` runs for all existing installs.

---

### MEDIUM

---

#### M1 — `_doRefresh` silently skips `onChanged` when SQLite persistence fails, leaving stream listeners permanently out of sync with in-memory state

**File:** `lib/src/services/translation_service.dart` — `_doRefresh`  
**Confidence:** 80

```dart
Future<void> _doRefresh(String lang) async {
  final map = await loadTranslations(lang); // populates _cache[lang] as a side effect
  if (_disposed) return;
  if (map.isEmpty) return;
  try {
    await _dao?.bulkUpsert(lang, map);
  } catch (e, st) {
    sdkLog('...');
    return;           // ← exits without emitting onChanged
  }
  if (!_changedController.isClosed) _changedController.add(null);
}
```

`loadTranslations` updates `_cache[lang]` regardless of whether `bulkUpsert` succeeds. If `bulkUpsert` throws (disk full, I/O error, schema mismatch), the early return exits without emitting `onChanged`. The in-memory cache is fresh — `translate()` returns updated strings — but no subscriber is notified. Any `StreamBuilder` or Riverpod stream provider listening to `translationService.onChanged` continues displaying stale translations for the rest of the session.

**Fix:** Move `_changedController.add(null)` outside the try/catch (after it), conditional only on `_cache[lang]` having been updated:

```dart
try {
  await _dao?.bulkUpsert(lang, map);
} catch (e, st) {
  sdkLog('...');
}
// emit regardless — cache was updated whether or not SQLite persisted
if (!_changedController.isClosed) _changedController.add(null);
```

---

#### M2 — CHANGELOG references `TranslationDao._openFuture` memoization that does not exist in the shipped code

**File:** `CHANGELOG.md`  
**Confidence:** 95

CHANGELOG: _"`TranslationDao._openFuture` memoization — prevents a TOCTOU double-open if two concurrent callers hit `_open()` before the first `openDatabase` resolves."_

`translation_dao.dart` at HEAD has 76 lines, no `_openFuture` field, and no `_open()` method. The DAO is constructed with an injected `Database`; there is no lazy open. This describes a design that was evaluated but not shipped.

An auditor checking whether a TOCTOU race is actually closed will search for code that doesn't exist and conclude the safety guarantee is present when it isn't documented.

**Fix:** Remove this CHANGELOG entry (the race doesn't exist — `TranslationDao` doesn't open its own connection). Replace with a note that the `_openFuture` design was superseded by the injected-`Database` constructor.

---

#### M3 — `onFfiInitFailure` is a first-class public constructor parameter with no CHANGELOG entry and no doc comment on the parameter itself

**File:** `lib/src/sdk/frappe_sdk.dart` constructor, `CHANGELOG.md`  
**Confidence:** 80

`onFfiInitFailure` is the integrator's hook for routing crash signals to Firebase Crashlytics, Sentry, or any similar service. It is a non-trivial new API surface. The CHANGELOG makes no mention of it. The constructor parameter has a doc comment on the field declaration but not on the constructor parameter itself, which is where IDEs surface documentation.

The companion tuning parameters added in the same constructor (`pullPageSize`, `syncServicePageSize`, `listChildDocsPageSize`, `listFullDocsPageSize`, `listDefaultPageSize`) also have no baseline guidance on appropriate values for different deployment scales.

**Fix:** Add a CHANGELOG entry under "Added" for `onFfiInitFailure`. Add a code example in the doc comment. Add `/// Defaults to N; increase for high-volume deployments` comments on the page-size parameters.

---

### LOW (informational — not blocking, not in the ≥80 filter, noted for completeness)

| # | File | Issue |
|---|------|-------|
| L1 | `lib/src/database/app_database.dart` | `_onCreate` doc comment still says "v3 shape"; now v4 |
| L2 | `lib/src/sdk/frappe_sdk.dart` ~line 756 | `translations` getter doc still says to use `loadTranslations` + `translate`; correct path is `loadFromCache` → `refreshAsync` → listen on `onChanged` |
| L3 | `lib/src/database/daos/outbox_dao.dart` | `recordSave` transaction guard is `assert` (stripped in release builds); a `StateError` throw would enforce the invariant in production |
| L4 | `lib/src/sync/pull_apply.dart` ~line 227 | `NOT IN ('done','in_flight')` — `'done'` is unreachable (rows are hard-deleted on done); misleading to future readers |
| L5 | `lib/services/translation_service.dart` | `injectDao()` has no `@visibleForTesting` annotation despite being a test-only hook; lint won't catch consumer misuse |
| L6 | `lib/src/ui/login_screen.dart` | Some errors are now localized via `sdkTr(...)` but catch-branch messages are still raw Dart exception strings; inconsistency is visible post-partial-migration |

---

## What Is Working Well

The following items were explicitly verified and found correct. Not calling these out in the bug list:

- `LinkDecorator.decorateBatch` chunking: correct at 900 variables per chunk (under SQLite's 999-variable limit); `isLocal/isServer` split before chunking is sound.
- `rest_helper.compute(jsonDecode)`: isolate exceptions propagate correctly to the awaiting future; every call site has an untyped catch. No issue.
- `OutboxDao.recordSave` collapse/dedup logic: `resetToPending(survivor)` + `DELETE WHERE id != survivor AND state IN (collapsable)` is the correct dedup sequence; the in-flight guard is sound.
- Migration tests: `migration_v3_to_v4_test.dart` correctly covers the critical v3→v4 path, idempotency (IF NOT EXISTS), data preservation, and round-trip usability.
- All prior targeted fixes from PRs #36, #43, #65 survive into HEAD unchanged: tombstone guard (sequential path), attachment backoff, `clearAllData` atomicity, `sdk_meta_dao` SQLite<3.24 compat, `ThreeWayMerge` deep equality, merge-retry recursion guard, `clearLocalConflict` state, `PhoneField` echo guard, `deleteDocument` attachment cleanup, stall guard scoping, write-queue completer lifecycle, response-writeback double-miss warn.
- 1434/1434 tests passing.

---

## Blocking vs Non-Blocking Summary

| ID | Severity | Blocking? | File |
|----|----------|-----------|------|
| C1 | Critical | YES | `lib/src/sync/pull_apply.dart` — `_applyPageInTxnBulk` |
| C1b | Critical | YES | `lib/src/sync/pull_apply.dart` — bulk child-UUID loop |
| H1 | High | YES | `lib/src/services/sync_service.dart` |
| H2 | High | YES | `push_engine.dart`, `outbox_dao.dart`, `sync_controller.dart` |
| H3 | High | YES | `frappe_sdk.dart`, `push_engine.dart`, `pull_engine.dart`, `app_database.dart` |
| H4 | High | YES | `CHANGELOG.md` |
| H5 | High | YES | `CHANGELOG.md`, `doc/TRANSLATIONS.md` |
| H6 | High | YES | `CHANGELOG.md` |
| M1 | Medium | No | `lib/src/services/translation_service.dart` |
| M2 | Medium | No | `CHANGELOG.md` |
| M3 | Medium | No | `lib/src/sdk/frappe_sdk.dart`, `CHANGELOG.md` |
| L1–L6 | Low | No | Various |
