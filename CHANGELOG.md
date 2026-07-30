# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - Unreleased

Major release: offline-first foundation, server-driven offline-mode toggle, and a new query/sync surface. Upgrades from `1.x` use a single transactional migration from database schema v2 to v3.

### Added

**Offline foundation**

- `OfflineMode` value object (`enabled`, `isPersisted`) bound to a session, plus `OfflineModeNotifier`. The mode is persisted in `sdk_meta` and re-resolved on each launch.
- `OfflineRepository` — primary write path for local edits; manages per-doctype tables and child rows via `LocalWriter`.
- `OfflineTransitionService` with sealed-state stream (`TransitionIdle`, `TransitionDraining`, `TransitionDrainFailed`, `TransitionWipingTables`, `TransitionCompleted`) plus `runDrainAndWipe()`, `retry()`, `forceExit()`. Drives the offline → online transition: drains pending records, then drops local data tables.
- `OfflineTransitionScreen` — full-screen transition UI with `PopScope` guard; drain progress, drain failure, retry, and force-exit flows.
- `OfflineTransitionGuard` — wraps a child widget and overlays the transition screen for as long as the SDK's transition stream is non-idle. Recommended integration point for consumer apps.
- `AtomicWipe` — deletes and rebuilds the SQLite database atomically; used during logout-wipe.
- `FrappeSDK.offlineTransition` getter and `runOfflineTransitionIfPending()` for explicit foreground orchestration.

**Query / read path**

- `UnifiedResolver` — single offline-first read path used by Link pickers, list screens, and `fetch_from`. DB-first; background API refresh when online.
- `FilterParser` + `ParsedQuery` — translate Frappe-style filter lists into parameter-bound SQLite queries; pure functions, no I/O.
- `QueryResult` + `RowOrigin` — read results carry per-row provenance (local edit vs server) for filter chips and observability.
- `LinkDecorator` + `TargetMetaResolver` — display companions for Link / Dynamic Link values.
- `FrappeTimespan` + `TimespanRange` — Frappe-style timespan keywords resolved to absolute ISO ranges offline.

**Link fields**

- `LinkFilterBuilder` callback — runtime filter builder for link-option fetch, keyed on the **target doctype**. Replaces static `linkFilters` JSON when dynamic field/row dependencies are needed.
- `LinkOptionService` — offline-first Link picker; routes through `UnifiedResolver` with DB-first reads and background refresh.
- `LinkFieldCoordinator` — dependency-aware sequencing and progress tracking for cascading Link fields.

**Sync engine**

- Cursor-based pull. `SyncService` uses `(modified, name)` cursors with `DoctypePullPhase` (`initial` / `resume` / `incremental`), look-ahead pagination, and resume-on-crash. Final-page lookahead persists `complete: true` and transitions to `incremental`.
- Tier-ordered push. `PushEngine` drains the outbox via `TierComputer`-grouped dispatch — tier 0 has no inter-pending dependencies; tier k depends only on tiers `< k`. Concurrent dispatch within a tier; stable order `createdAt asc, id asc`.
- L1 / L2 / L3 idempotency on INSERT. L1 uses `autoname=field:mobile_uuid`; L2 uses a consumer-supplied dedup hook; L3 GETs by `mobile_uuid` to detect prior successful POSTs before retry.
- `pullSyncMany` — batch pull for multiple doctypes through a bounded worker pool.
- `getPullPhase` / `getPullPhases` — query pull phase per doctype for UX gating (blocking screen vs background indicator).
- UUID rewrite on push. `UuidRewriter` rewrites Link fields containing `mobile_uuid` values to their `server_name` before push, using `<field>__is_local` companion columns.
- Three-key child identity match on pull-apply (`server_name → mobile_uuid → position`); preserves UUIDs across re-pulls and avoids orphaning Link references.
- `SyncController` — public imperative surface: `syncNow`, `pause` / `resume`, `retry`, `retryAll`, `resolveConflict`, `previewDeleteCascade`, `acceptDeleteCascade`. Observable `state$` stream.
- `SyncState`, `DoctypeSyncState`, `QueueSummary`, `SyncErrorSummary`, `SyncStateNotifier` — composable sync-state snapshot for UI widgets; per-doctype progress, queue counts, last error.
- `RetryPriority` — reorders outbox rows for "Retry all" so user-visible errors retry first.

**Error capture**

- Side-channel capture of terminal push failures. When a push drain hits a permanent server rejection (`4XX` / terminal `401` / `5XX`), the SDK records the exact wire request, the raw server response, and the session user's identity and roles — enough for a developer to reconstruct a replayable request with the same payload and permissions. Capture is automatic at the engine's `send()` boundary and rethrows the original error unchanged; the host app wires nothing up.
- `ErrorLogCollector` — aggregates failures per drain by a stable client-computed `signature`, accumulates an occurrence count, and keeps a rolling window of the most recent 5 example payloads. Emits a `MobileErrorRecord`.
- `MobileErrorPoster` — best-effort POST of the aggregated record to the server's `mobile_sync.report_error` endpoint after each drain (`PushEngine.onDrainComplete`); failures to report are dropped silently so capture never affects sync.
- Wire metadata on exceptions. `FrappeException` now carries `requestUrl`, `requestMethod`, request `body`, raw `responseBody`, and `traceId`; `rest_helper` stamps these on any `>= 400` response (and the `403` / `404` paths no longer drop the raw body).
- `SessionUserService` is created and restored **before** the sync engine is built so captured records carry the real reporting user and roles rather than a guest/empty identity.

**Sync UI**

- `SyncStatusBar`, `SyncProgressScreen`, `SyncErrorsScreen` — status bar, blocking bootstrap-pull screen, errors list with per-row Retry / View error / Open actions and a header Retry-all.
- `DocumentListFilterChip` (with `DocumentListFilter` / `DocumentListFilterCounts`) — Material `SegmentedButton` chip for tri-state filtering (all / unsynced / errors) with live counts.
- `showDeleteCascadePrompt` (with `DeleteCascadeAction`) — shown when DELETE fails with `LinkExistsError`; lets the user delete-all, fix-manually, or cancel.
- `showLogoutGuardDialog` (with `LogoutGuardAction`) — soft-gate dialog when Logout is tapped with unsynced rows.
- `showForceLogoutConfirm` — hard-gate dialog requiring "LOGOUT" text entry before destructive logout.

**Session**

- `SessionUser` value object plus `SessionUserService` — owns the in-memory session user and publishes changes via stream.
- All login paths (username/password, OTP, API key, OAuth) now populate `SessionUser` automatically. `sdk.sessionUser` and `sdk.sessionUser$` are available immediately after login.
- Persisted to `sdk_meta.session_user_json` so restore-session paths rehydrate without an extra round-trip.

**Server-driven offline-mode toggle** (companion server feature)

- New `offline_enabled` Check field on the server-side `Mobile Configuration` doctype controls whether the SDK runs as an offline-first client or a thin online client. Default is **off** (online).
- Companion server release: `frappe-mobile-control` 1.x with `offline_enabled` surfaced on every authenticated login response.
- `SdkMetaDao` — read/write helpers for the persisted offline-mode flag on `sdk_meta`.

**Other**

- `ClosureBuilder` — parallel BFS, level-by-level meta fetching with bounded concurrency (default 4 workers); reduces closure build time on large schemas.
- `DoctypeService.bulkGetWithChildren` — single POST to the `mobile_sync.get_docs_with_children` endpoint for a chunk of names. Companion `DoctypeService.listFullDocs` paginates names from `get_list`, splits them into 200-name chunks (matching the server-side `MAX_BATCH`), and on `404` falls back to per-name `GET` requests with bounded concurrency (slice size 20) for older deployments.
- `DoctypeService.list` accepts an optional `orFilters` parameter (additive; passes Frappe's `or_filters` query param through).
- `RestHelper` — error messages distinguish "connection refused" from "no internet".
- `FormScreen` offline-first save — checks connectivity before save; treats `serverId == null` docs as INSERT when going back online.
- `ApiTracer` — debug-mode tracing utility for API calls.
- `extractErrorMessage` / `toUserFriendlyMessage` — shared helpers for error-string normalization across the SDK.
- `LinkFieldPickerMode` enum (`inline` and `dialog` modes) to support alternative full-modal lookup dialogs for Link and Table MultiSelect fields, configurable globally via `FrappeFormStyle`.
- `SearchableSelectDialog` widget rendering a modal dialog with a dedicated search filter, checkboxes for multi-select, and checkmarks for single-select.
- `FrappeFormBuilder.cascadeProgrammaticChanges` (default `false`) — when enabled, a value written programmatically by an `onFieldChange` patch (e.g. a computed value, or a value the handler fetched from a linked document and returned as a patch) re-fires that field's own change pipeline, so dependent fields recompute. Mirrors Frappe Desk's `frm.set_value` → trigger behaviour. Loop-safe via value-equality plus a depth cap; the synchronous `patchValue` echo is suppressed so each handler fires once (no double-run for typed fields whose representation `FieldNormalizer` changes). Covers handler-returned patches only: the SDK's native `DocField.fetchFrom` patches use a separate internal path and do not cascade (see `doc/COMPUTED_FIELD_CASCADE.md`, "Known limitation"). Cascade re-fires now pass `ChangeSource.reaction` to `onFieldChange` (the originating user edit stays `ChangeSource.user`), so a handler can gate one-shot side effects on `source == ChangeSource.user`; with the flag off every invocation remains `ChangeSource.user`.

**Translation pipeline (PR #76)**

- `TranslationDao` — KV store for offline translation persistence (schema: `(lang, src, tgt)`). The `kv` table lives **inside `AppDatabase`** (the main app database), not in a separate file. `TranslationDao` is constructed with an injected `Database` handle; `close()` is a deliberate no-op (AppDatabase manages the connection lifecycle). Cleared via `TranslationService.clearAll()` or `AppDatabase.clearAllData()`. `TranslationDao.forTesting()` opens an isolated in-memory DB. Methods: `bulkUpsert`, `readAll`, `deleteAll`.
- `TranslationService` — offline-capable translation service with `loadFromCache` (SQLite, <5 ms), `refreshAsync` / `refreshAllAsync` (fire-and-forget network), `translateDelegate` hook for host-app ARB priority lookup, `onChanged` broadcast stream, `clearAll`, and `dispose()`.
- `TranslationService.fetchEnabledLanguages()` — queries `frappe.client.get_list` on the `Language` doctype to discover all enabled language codes.
- `TranslationService.refreshAllAsync()` — calls `fetchEnabledLanguages()` then `_doRefresh(lang)` for every enabled language; fires once per login. Ensures the offline cache covers all languages the deployment supports.
- `TranslationService.clearAll()` — clears in-memory cache, resets `_currentLang = 'en'`, and calls `TranslationDao.deleteAll()`. Wires into `FrappeSDK.logout(clearDatabase: true)`.
- `FrappeTranslations` static registry + `sdkTr()` top-level helper — exported from `frappe_mobile_sdk.dart`. Host apps call `FrappeTranslations.setDelegate(sdk.translations.translate)` once (e.g. in a Riverpod listener) to route `sdkTr()` through the live `TranslationService`.
- `TranslationService.translateDelegate` — nullable `String Function(String, [List<Object>?])?` field on `TranslationService`. When set, the delegate is called first; if it returns a value different from the source, that value is used (ARB wins). Otherwise falls through to `translateLocal` (SQLite). Lets host apps inject their compiled ARB lookup without the SDK knowing about Flutter's localization layer.
- `doc/TRANSLATIONS.md` — consumer guide covering architecture, `sdkTr` usage, host app integration, ARB lookup, SQLite fallback, locale lifecycle, reactive rebuild path, dispose safety, and why `sdkTr` not `tr`.
- `doc/PHONE-FIELD.md` — documents the PhoneField storage contract, `toStored`/`numberFromStored` invariants, the echo-guard that prevents OOM, regression history, and integration checklist.
- `doc/OUTBOX-STATE-MACHINE.md` — documents all 7 outbox states, state transitions, supersede pass logic, `isOwnInsertRoundtrip` ghost-success data-loss scenario and fix, `recordSave` duplicate-INSERT prevention, and error-surfacing invariants.
- **`LinkOptionService.getLinkTitle(doctype, name)`** — resolves a single Link VALUE to its display title, offline-first. Parent list rows get this for free (the resolver runs `LinkDecorator.decorateBatch`, which adds a runtime `<field>__display` companion to each row map), but child-table rows are read by `mergeChildRowsIntoData` straight out of `docs__<child>` and are never decorated — so this is the only title path for a Link cell inside a child-table grid, which would otherwise render an opaque id. Bounded by construction: a 500-entry LRU cap and single-flight dedupe, so N cells pointing at the same target await ONE resolve. Misses are deliberately not cached, keeping the lookup retryable while the target doctype is still pulling.
- **`FieldFactory.capDataLength` / `FieldFactory.errorTextResolver`** — the Single-doctype `Data` length exemption and the child-table inline-error lookup, carried as instance state alongside the existing `linkOptionService` / `linkFieldCoordinator`. Deliberately **not** `createField` parameters: that method is documented as overridable, and Dart requires an override to redeclare every named parameter of the method it overrides — so adding one breaks every existing subclass at compile time, and a default value does not help (a caller holding a `FieldFactory` reference may still pass the argument explicitly). `createField`'s signature is unchanged from `2.0.0`'s baseline and should be treated as frozen.
- **`DocField.isVirtual`** — parsed from Frappe's `is_virtual` DocField flag (accepts int `1`/`0`, bool, or `"1"`, like every other Check flag). A virtual DocField has no database column, so it is now excluded from the `fields: ['*']` expansion; emitting it sent a nonexistent column to `frappe.client.get_list`. Serialized unconditionally by `toJson` because field JSON round-trips through the local meta cache — omitting the key would drop the flag on the next cold start.

### Changed

- **Single read path.** All list reads route through `UnifiedResolver`. DB-first with background refresh on connectivity; Link decoration via `LinkDecorator`.
- `SearchableSelect` updated to support launching `SearchableSelectDialog` when `pickerMode` is `LinkFieldPickerMode.dialog`.
- **`pullSync` guards child doctypes.** Doctypes with `istable=1` are skipped at the entrypoint — `frappe.client.get_list` does not permit listing them, and children arrive embedded in parent pulls.

- **Form-level cascade clears.** When a Link field changes, the SDK auto-clears dependent Link fields whose `linkFilters` contain `eval:doc.{fieldname}` references. Consumer `FieldChangeHandler` callbacks should add value-derivation only — the form owns cascade cleanup.
- **Local UUID resolution.** Values matching the v4-UUID shape resolve from `docs__*` only; the SDK never calls `getByName(...)` for UUID-shaped values, since server names never match the UUID pattern.
- **Conflict surfaces.** When a pulled row is newer than a local dirty/failed row, `PullApply` sets `sync_status = 'conflict'`. Resolve via `SyncController.resolveConflict()` with two actions: `pullAndOverwriteLocal` (apply server snapshot) or `keepLocalAndRetry` (requeue; runs `ThreeWayMerge` against the pre-edit base).
- **Mobile-UUID round-trip.** After a successful first push, `OfflineRepository.reconcileServerSave` attaches the server's `server_name` to the local row keyed by `mobile_uuid`, cancels pending outbox rows for the pair, and applies the full server snapshot so server-derived columns (defaults, formulas) land in the mirror.
- **`OfflineRepository`** constructor — `database` is positional; `localWriter`, `offlineMode`, `offlineModeNotifier`, `client`, and `metaFetcher` are named. When the effective offline mode is off, `create` / `updateDocumentData` / `deleteDocument` route to `FrappeClient` directly; `getDirtyDocuments` returns empty.
- **`OfflineRepository.createDocument`** — preserves an existing `mobile_uuid` from the payload rather than always generating a fresh one.
- **`OfflineRepository.getRowFromPerDoctypeTable`** — added for `fetch_from` offline resolution.
- **`UnifiedResolver`** — translates the `parent` filter column to `parent_uuid` for child-table queries. All constructor parameters are named: `db`, `metaDao`, `isOnline`, `backgroundFetch`, `metaResolver` are required; `offlineMode`, `offlineModeNotifier`, `client` are optional. When the effective offline mode is off, `resolve()` short-circuits to a REST passthrough (no DB read, no `LinkDecorator`, no background-refresh dedupe).
- **`LinkOptionService`** constructor — now takes `UnifiedResolver` and a meta-resolver instead of `FrappeClient`.
- **`SyncService`** — `client`, `offlineRepository`, `database` are positional; `getMobileUuid`, `offlineMode`, `offlineModeNotifier`, `pushRunner` are named. `pushRunner` is the production push driver (`FrappeSDK` wires it to `PushEngine.runOnce`); `pushSync` returns `SyncResult.empty()` and logs a warning if it's unset. Every public method (`pushSync`, `pullSync`, `pullSyncMany`, `syncDoctype`, `getSyncStats`) returns `SyncResult.empty()` (or zeros) when the effective offline mode is off. Adds the `SyncResult.empty()` factory.
- **`FrappeSDK.initialize()`** — reads the persisted offline-mode flag, resolves the session-bound mode via `_resolveBootMode`, and gates closure pull in `_initialMetaAndDataSync` accordingly. `autoRestoreAndSync` defaults to `false`; when `true`, restores session and runs post-login bootstrap.
- **`FrappeSDK.forTesting`** — accepts an `offlineMode` parameter (default: offline) so existing tests continue to exercise the offline path.

### Removed

- **`DocumentDao`** — deleted, no replacement. All single-bag CRUD is replaced by `OfflineRepository` + `UnifiedResolver`.
- **Legacy `documents` table** — dropped during the v2 → v3 migration. The single-bag JSON store is replaced by per-doctype `docs__<doctype>` tables. Drop is safe because `1.x` devices push before persisting, so there are no unsynced rows in `documents` at upgrade time.

### Schema

- **`AppDatabase._version` is `6`.** `sdk_meta.schema_version` is written in lockstep by both `_onCreate` and all upgrade paths.
- **Migration step `_migrateV2ToV3`** runs within one transaction: (1) safely add v3 + v4 column extensions to `doctype_meta` via wrapped `ALTER TABLE ADD COLUMN` (catches "duplicate column name"); (2) idempotently create system tables (`outbox`, `pending_attachments`, `sdk_meta`) with `CREATE TABLE IF NOT EXISTS`; (3) drop the legacy `documents` table and its indexes; (4) upsert the singleton `sdk_meta` row with `schema_version = 3`.
- **Migration step `_migrateV3ToV4`** (new — runs for all existing v3 installs): creates the `kv` table (offline translation cache, `PRIMARY KEY (lang, src)`) inside `AppDatabase` using `CREATE TABLE IF NOT EXISTS`; updates `sdk_meta.schema_version = 4`. Fresh installs also receive the `kv` table via `systemTablesDDL()`.
- **Migration step `_migrateV4ToV5`**: adds the two tamper-detection tables (`security_state`, `security_events`). Every statement is `CREATE TABLE IF NOT EXISTS` / `INSERT OR IGNORE`, so an interrupted upgrade is safe to re-run.
- **Migration step `_migrateV5ToV6`** (new): materializes Frappe's server-owned audit columns `owner`, `creation`, and `modified_by` as nullable `TEXT` on every existing `docs__<doctype>` **parent** mirror, via wrapped `ALTER TABLE ADD COLUMN`; updates `sdk_meta.schema_version = 6`. Fresh installs receive the columns from `parent_schema.dart`.
  - This has to be a **versioned** migration rather than relying on the per-doctype reconcile: `FilterParser` now emits real SQL for these columns instead of silently dropping the clause, so a table created by an older build would fail such a query with `no such column: owner`. The reconcile paths only run during a pull and the closure pull is connectivity-gated, so an app that upgrades and then starts **offline** would query the old schema first. `onUpgrade` runs inside `openDatabase`, before any query can execute — so no such window exists.
  - **Child** mirrors share the `docs__` prefix but never carry these columns (`child_schema.dart` does not emit them), so they are identified by the absence of the parent-only `sync_status` column and left untouched. This keeps an upgraded install's child tables from drifting away from a fresh install's.
- **Upgrade paths:** v2→v6 runs every step in order; each intermediate version runs only the steps it still needs; fresh installs skip all of them. Every path produces identical final schema.
- **Storage layers:**
  - **Per-doctype mirror** — `docs__<doctype>` tables with `mobile_uuid` PK, `server_name`, `sync_status`, `sync_op`, `push_base_payload`, and field columns. Children carry `parent_uuid`. Tables are **lazily created** on first pull via `OfflineRepository.ensureSchemaForClosure`.
  - **System** — `sdk_meta` (singleton row tracking `schema_version`, bootstrap state, offline mode, session user); `outbox` (operation log indexed by state + created_at); `pending_attachments` (file upload queue with retry); `kv` (offline translation cache).
  - **Per-doctype mirror parent tables** additionally carry Frappe's audit columns `owner`, `creation`, `modified_by` (nullable `TEXT`, server-written only — the SDK never fabricates them locally, and they are stripped from every outbound payload so a client cannot forge `owner`).
- Fresh installs and every upgrade path end in identical schema state (`schema_version = 6`).

### Fixed

- **`DependsOnEvaluator` — quoted string literals were being rewritten.** `_normalizeOperatorSpacing` has a quote-aware loop, but its final global `replaceAll(RegExp(r' {2,}'), ' ')` ran afterwards and undid that awareness, collapsing runs of spaces *inside* string literals. Any Select option or Data value containing two consecutive spaces silently failed its comparison, mis-gating `depends_on` visibility, `mandatory_depends_on`, and read-only. `eval:doc.status == "In  Progress"` against `'In  Progress'` returned `false`. Space collapsing now happens inside the quote-aware loop, so quoted contents are byte-identical to the input.
- `DependsOnEvaluator` — a bare `>` preceded by `=` (a JS arrow function, `r => r.x`) was spaced into `r = > r.x`, which then matched the `>` comparison branch instead of falling through to the truthy fallback. Guarded.
- **`FilterParser` no longer silently drops `owner` / `creation` / `modified_by` clauses.** These audit columns were absent from the offline schema, so a clause referencing one was dropped with a log line — making offline results a **superset** of the server query. An `owner = <current user>` filter became a no-op and surfaced rows that were not the user's. The columns are now materialized (see **Schema**) and the clauses emit real parameter-bound SQL. Genuinely-unknown columns still throw. Child doctypes still throw for these columns, since `child_schema.dart` never emits them — whitelisting them for children would have generated SQL against a nonexistent column, turning a silent superset into a crash.
- **Documents created offline were invisible in their creator's own list.** `LocalWriter` now stamps a local prediction on a device-created parent row — `owner` / `modified_by` = the session user, `creation` = now — so an `owner = <me>` filter finds the user's own draft before it ever syncs. The prediction is never sent to Frappe (these columns are stripped from every outbound payload and from the `ThreeWayMerge` base, so a client cannot forge `owner`), and server truth overwrites it from both directions: `PullApply` on pull and `ResponseWriteback` on a successful push. An UPDATE preserves the existing `owner` / `creation`; only `modified_by` moves. With no session user available the fields stay NULL, exactly as before.
  - `creation` is formatted `YYYY-MM-DD HH:MM:SS` to match Frappe's wire format. This is deliberate, not cosmetic: `creation` is a TEXT column compared with plain SQL, and `' ' (0x20) < 'T' (0x54)`, so an ISO-8601 `T` separator would sort after every server-supplied value on the same date and silently break `creation >= ...` range filters.
- **`ResponseWriteback` dropped the server's audit values.** It wrote back only `server_name` / `modified` / `sync_status`, so a freshly-pushed document kept its local prediction until the next full pull. It now also persists `owner` / `creation` / `modified_by` from the push response, guarded by a hoisted `PRAGMA table_info` check — an unguarded `UPDATE` against a table lacking the columns would throw *inside the push transaction*, rolling back the whole writeback and leaving the outbox to re-push a document the server had already accepted (duplicate-creation risk).
- `PullPageFetcher` — `_fieldsToRequest` built `{'name','modified'}` plus meta fieldnames, and the audit fields are never in `meta.fields`, so the primary closure pull never requested them. Left unfixed alongside the `FilterParser` change, an `owner = me` list would have returned **nothing**.
- **A required-empty child table blocked Save with no visible error.** Neither `ChildTableField` (`Table`) nor `TableMultiSelectFieldBase` (`Table MultiSelect`) is a `FormBuilderField`, so `invalidate()` was a silent no-op for both and the user got a dead Save button. Both now render an inline error, in the legacy mandatory sweep and in reactive mode. The reactive path subscribes to the controller's error listenable, which also *creates* the notifier — so a field that mounts after validation (a lazily-built tab) still receives the message on arrival.
- `FormController._validateField` — a whitespace-only value counted as PRESENT for a required field, disagreeing with the legacy sweep's trim-aware check. Aligned on the trim-aware semantics. `0`, `0.0`, and `false` remain "set"; an empty list remains missing.
- `DataField` — the implicit 140-char `Data` cap was enforced with the counter suppressed, so typing simply stopped with no explanation and no message. The counter now appears within 20 characters of the cap on editable fields, and stays hidden otherwise to match the web UI.
- `AttachField` — remote attachment downloads had no timeout and buffered the entire response into memory via `bodyBytes` (OOM risk on a large PDF or video), and the temp file was named from the attachment's basename, so two attachments sharing a basename collided and served stale bytes. Now streamed with a 30s timeout, a 50 MB cap enforced against both `content-length` and a running byte count, and written to a dedicated subdirectory under a URL-derived filename that preserves the extension. Partial files are deleted on every failure path.
- `ImageField` — the Android activity-kill camera recovery called `retrieveLostData()` before *every* capture. That cache is process-wide, so a photo captured for one field could be claimed by a different one, and the user's explicit tap to take a new photo silently restored an old one instead. Recovery is now gated on a persisted per-field marker (`retrieveLostData()` *clears* the platform cache, so a non-owning field must never call it), bounded to 30 minutes, and announces the restore instead of swallowing the tap.
- `ServerRejection.message` — re-ran `jsonDecode` on the raw body on every read. Memoized; the returned string is unchanged for every input, including the malformed-body and `Unknown Error` fallbacks.
- `DocField.displayLabel` — allocated its zero-width-character `RegExp` on every call, on widget build paths. Hoisted to a `static final`.
- `FrappeFormBuilder` — a `onFieldChange` handler patching the **same field that is changing** with a rewritten value (e.g. normalising `'hi'` → `'HI'`) crashed with an unbounded synchronous recursion (`StackOverflowError`) through the text field's controller notifications; independent of `cascadeProgrammaticChanges`. The self-key's widget patch is now deferred one frame (form data still updates immediately). Regression-tested for both flag states.
- `system_tables.dart` — all `CREATE TABLE` statements use `IF NOT EXISTS`; `sdk_meta` seed uses `INSERT OR IGNORE` for migration idempotency.
- `pull_apply.dart` — conflict flag now only fires when the server `modified` timestamp is strictly after the local `modified` (previously flagged any dirty row unconditionally).
- `SyncController.pause()` / `resume()` — `syncNow` now checks the `isPaused` flag before running.
- `BaseField` — wrap field labels in `Expanded` and use `CrossAxisAlignment.start` to prevent horizontal `RenderFlex` overflows when field labels contain long text (Issue #52).
- `FrappeFormBuilder` — replace `SingleTickerProviderStateMixin` with `TickerProviderStateMixin` to prevent "Multiple Tickers" crashes, and utilize `mapEquals` deep comparison for `initialData` in `didUpdateWidget` to avoid unnecessary controller teardowns and state resets (Issue #72).

**Translation pipeline (feat/sdk-offline-phase2 — PR #76)**

- `TranslationService.loadTranslations` — continues to call `mobile_auth.get_translations` (the `frappe-mobile-control` custom method). `frappe.client.get_list('Translation')` was evaluated but not adopted: it returns only user-created custom translations and misses the compiled `.po` translations that supply field labels. The `frappe-mobile-control` backend is still required.
- `TranslationService.refreshAllAsync` — fires once per login to pull translations for **all** enabled languages, not just the current user's language. Ensures the offline SQLite cache is fully populated for every language the deployment supports, so offline sessions have no missing translations regardless of locale.
- `TranslationService.clearAll` (+ `TranslationDao.deleteAll`) — called from `FrappeSDK.logout(clearDatabase: true)`. Clears the in-memory translation cache and wipes the `kv` table inside `AppDatabase` on logout so a different user logging into the same device never sees stale translations.
- `TranslationService._disposed` flag — guards `loadFromCache` and `_doRefresh` against writing to a closed `StreamController` or DAO when `dispose()` fires during an in-flight network call.
- `TranslationDao` constructor — accepts an injected `Database` handle, eliminating any lazy-open pattern. No `_open()` method exists; the TOCTOU race cannot occur.
- `sdkTr` global helper — renamed from `tr` to avoid naming collisions with `easy_localization` and GetX in host apps. Host apps should define a local `tr(String s) => FrappeTranslations.translate(s);` wrapper instead of importing `sdkTr` directly.

**Outbox state machine (feat/sdk-offline-phase2 — PR #76)**

- `PushEngine._drainOnce` supersede pass — extended to include `paused` rows alongside `failed`. A stale paused row from a prior terminal rejection is now cleaned up when a newer `pending` row covers the same `(doctype, mobile_uuid, operation)` tuple, preventing phantom errors in the UI.
- `SyncController._allActionableRows` + `OfflineRepository.getSyncErrorsForDoc` — `paused` rows are now included in all error-surfacing queries. They appear in SyncErrorsScreen, document badges, and the per-document form banner. `retryAll` still excludes `paused` (bulk-re-queuing a terminal rejection is incorrect; re-save is the resume path).
- `OutboxDao.recordSave` — when a paused + pending INSERT pair co-existed for the same document, `firstWhere` reset one row and returned, leaving the second row alive. Both rows then dispatched, producing two INSERTs for the same document. Fixed by deleting all remaining collapsable same-operation rows after resetting the survivor.
- `PullApply.isOwnInsertRoundtrip` — when a ghost-success INSERT left `server_name NULL` and the user re-edited before write-back, the dirty-conflict guard was bypassed and local edits were silently overwritten on the next pull (data loss). Fixed by checking the outbox for any non-done, non-in_flight rows for the matched `mobile_uuid` before accepting the round-trip flag; if owed work exists, the flag is cleared and the normal conflict guard runs.

**PhoneField (feat/sdk-offline-phase2 — PR #76)**

- `PhoneField.toStored` — regression introduced in `0a33fbe` called `numberFromStored()` (the inverse operation — strips `+91`) instead of prepending the dial code. Every phone entered or edited on device was stored as bare digits with no country code. Fixed by reverting to the correct form: `return '$_defaultDialCode$digits'`. Test expectations restored to `+919876543210`. The echo-guard invariant (`numberFromStored(toStored(digits)) == digits`) is unaffected — no OOM regression.

**Misc (feat/sdk-offline-phase2 — PR #76)**

- `FrappeSDK.onFfiInitFailure` — optional `void Function(Object, StackTrace)?` constructor parameter. Called when SQLite FFI initialisation fails before the MethodChannel fallback activates. Wire to your crash reporter to capture non-fatal FFI errors without blocking SDK startup. Example: `onFfiInitFailure: (e, st) => FirebaseCrashlytics.instance.recordError(e, st, fatal: false)`.
- `FrappeSDK` page-size constructor parameters — `pullPageSize` (default 500), `syncServicePageSize` (default 1000), `listChildDocsPageSize` (default 1000), `listFullDocsPageSize` (default 1000), `listDefaultPageSize` (default 20). Tune for your server's response-time profile; higher values reduce round-trips at the cost of larger per-request payloads.
- `FrappeAppGuard.allowDeferringUpdates` — default was `false` but documented as `true`. The deferrable-update branch in `_checkAppStatus` never assigned `deferrableUpdate = true` because the `else` branch was missing. Both defects fixed.
- `debugPrint` → `sdkLog` migration completed across `translation_service.dart`, `doctype_service.dart`, `login_screen.dart`, `sync_status_screen.dart`, `form_screen.dart`, `document_list_screen.dart`, and `app_guard.dart`. `sdkLog` is a no-op in release builds; `debugPrint` was not.
- `doc/FIELD_TYPES.md` — `SearchableSelect` / `SearchableSelectDialog` usage examples marked as internal (not exported from the barrel).

### Notes for upgraders

- All new constructor parameters are optional with sensible defaults; existing call sites continue to compile and run.
- Offline mode is **off by default**. To run as an offline-first client, deploy the `frappe-mobile-control` server release that flips `offline_enabled = true` on `Mobile Configuration` **before** upgrading the SDK on devices. An offline deployment that does **not** flip the flag will see clients persist `false` on first login and drain + wipe local data on the next launch.
- Token refresh does not refresh the offline-mode flag. Long-lived sessions stay in their previous mode until the user re-authenticates (password / OTP / OAuth / API key).
- Existing tests that use `FrappeSDK.forTesting` continue to default to offline. To exercise the online-only path in tests, pass `offlineMode: const OfflineMode(enabled: false, isPersisted: true)`.
- Downgrade is not supported. `sqflite` does not provide a downgrade hook; users cannot downgrade through the app stores.
- **Schema v6 runs automatically.** `_migrateV5ToV6` executes inside `openDatabase`, before any query can be issued, so an app that upgrades and then launches with no connectivity is safe. No host action is required.
- **Locally-created rows now carry a non-NULL `owner`.** If any host code treats `owner IS NULL` as a proxy for "not yet synced", that inference no longer holds — use `sync_status` or `server_name IS NULL` instead. A search of the SDK found no such consumer, but host apps reading the mirror tables directly should check.
- `FilterParser` now emits real SQL for `owner` / `creation` / `modified_by` on parent doctypes instead of dropping the clause. Any offline list that appeared to include rows beyond the user's own will now correctly exclude them — expect result sets to **shrink** to match the server. A filter on these columns against a **child** doctype throws `Unknown column`, because child mirrors do not carry them.

# [1.1.0](https://github.com/dhwani-ris/frappe-mobile-sdk/compare/v1.0.0...v1.1.0) (2026-04-17)


### Bug Fixes

* **auth:** disable social login and auto-discovery ([4382822](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/43828221e73e119c986a6329aa53473eb6964060))
* **review:** move docs to doc/FIELD_TYPES.md, remove pubspec.lock from tracking ([72f7c74](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/72f7c745af60272f1df5a390d0be6366a470f39b))


### Features

* add optional field change handler and improve form data handling ([9012b3e](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/9012b3e1ee02386472793ef8ad07c28387ad4b0e))
* **auth:** implement social login support with OAuth integration ([e123df7](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/e123df7809f806825bf9554087adec24ba616890))
* **fields:** add SearchableSelect, TableMultiSelect, Geolocation field widgets and fix form data handling ([06e8a32](https://github.com/dhwani-ris/frappe-mobile-sdk/commit/06e8a327dc0590c9d8d6c0c797104d6540c695a0))

## [1.0.0] - 2026-04-01

### Added

- Initial stable release of **Frappe Mobile SDK** for Flutter (`frappe_mobile_sdk`).
- **Frappe API client** — authentication (password, OAuth, API key, mobile OTP), CRUD, file upload, custom methods, and query-style access via `FrappeClient`.
- **Stateless mobile auth** — `mobile_auth.login` integration with token persistence, session restore, and automatic token refresh.
- **Dynamic forms** — metadata-driven rendering from Frappe DocTypes (`FrappeFormBuilder`, list and document screens).
- **Offline-first data layer** — SQLite storage, offline repository, and bi-directional sync with conflict handling.
- **App guard** — `FrappeAppGuard` for server-driven app status, versioning, and force-update flows (requires [Frappe Mobile Control](https://github.com/dhwani-ris/frappe_mobile_control) on the server).
- **Translations** — load dictionaries from the server and apply to labels in forms and lists.
- **Workflows** — workflow state and transitions on forms when configured on the DocType.
- Example app under `example/` and in-repo docs under `doc/`.

[2.0.0]: https://github.com/dhwani-ris/frappe-mobile-sdk/releases/tag/v2.0.0
[1.0.0]: https://github.com/dhwani-ris/frappe-mobile-sdk/releases/tag/v1.0.0
