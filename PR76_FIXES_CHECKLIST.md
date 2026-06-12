# PR #76 Post-Senior-Review Fixes — Checklist

> **Branch:** `feat/sdk-offline-phase2`  
> **Reviewer findings source:** Senior code review (verified by automated reviewer), 2026-06-12  
> **Implementation plan:** `doc/superpowers/plans/2026-06-12-pr76-senior-review-fixes.md`

---

## Status Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fixed & committed |
| 🔲 | Open — not yet started |
| ⏭ | Not a bug — PR comment only |
| 🗂 | Already fixed in earlier commit |

---

## Fixes

| # | Severity | Finding | File | Status |
|---|----------|---------|------|--------|
| 1 | HIGH | Bulk path: `else` branch doesn't guard against `server_name IS NULL` rows — offline-created records silently duplicate during initial sync | `lib/src/sync/pull_apply.dart` | 🔲 |
| 2 | HIGH | Multi-select required validator passes empty `[]` — `[].toString() == "[]"` bypasses empty check | `lib/src/ui/widgets/fields/field_helpers.dart` | 🔲 |
| 3 | HIGH | `didUpdateWidget` meta guard checks `name` only — structural tab/section changes (same name) skip `TabController` rebuild, causing length mismatch crash | `lib/src/ui/widgets/form_builder.dart` | 🔲 |
| 4 | LOW | `clearAll()` race: in-flight `refreshAllAsync` repopulates wiped cache after logout — no generation guard | `lib/src/services/translation_service.dart` | 🔲 |
| 5 | LOW | `fileName!` null-assert in `attachment_pipeline.dart:124` crashes on legacy/corrupt rows with `serverFileUrl` set but `serverFileName` null | `lib/src/sync/attachment_pipeline.dart` | 🔲 |
| 6a | LOW | `parseTime` dead code — zero callers confirmed | `lib/src/utils/date_helpers.dart` | 🔲 |
| 6b | — | Cursor checkpoint "duplication" — intentional design (two separate pull paths: `PullEngine` vs `SyncService._pullOneInternal`) | PR comment only | ⏭ |
| 6c | — | Serial `refreshAllAsync` — intentional design; WIP comment to be added (future: paginated bulk API) | `lib/src/services/translation_service.dart` | 🔲 |
| 6d | — | `bulkUpsert` no cache pruning — known limitation; add doc comment | `lib/src/database/daos/translation_dao.dart` | 🔲 |
| 7 | DOC | CHANGELOG/doc `translations_cache.db` overstatement | Already fixed | 🗂 |

---

## Post-Implementation

- [ ] `flutter test` full suite — 0 failures
- [ ] PR reply comment written (see plan §PR-REPLY)
- [ ] All `🔲` rows flipped to `✅`
