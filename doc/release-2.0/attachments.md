# Attachments — `frappe_mobile_sdk` 2.0

How an attachment travels from a camera tap to a Frappe `File` record and back onto the screen, including offline.

Every claim is grounded in code. Cites use `file::symbolName` form; line numbers appear only when pointing into the middle of a method body. Diagrams use [Mermaid](https://mermaid.js.org/) — GitHub, GitLab and pub.dev render them inline.

---

## 1. The problem this design solves

An attachment is the only part of a Frappe document whose bytes cannot travel inside the document. The field holds a *reference* (`/files/photo.jpg`), and that reference does not exist until a separate upload has happened. Offline, that upload cannot happen at save time — so the field has to hold something else in the meantime.

2.0 holds a **marker**: `pending:<id>`, pointing at a row in `pending_attachments`. The pipeline's whole job is to make sure a marker is *never* the thing that reaches the server.

That is harder than it looks, because the payload is rebuilt from the local mirror on **every** dispatch (`payload_assembler::PayloadAssembler.assemble`), not cached from the first attempt. So marker resolution must be correct on attempt 1, attempt 2, and after a crash — not just on the happy path.

---

## 1a. Which flows this touches — it is **not** push-only

A reasonable first assumption is that this is a sync/push feature. It is not. The work spans six flows, and only one of them is the push pipeline:

| Flow | What changes here | Push pipeline involved? |
|---|---|---|
| **Pick** | size guard before staging, terminal/transient split, staging layout, inline upload when online | No |
| **Save** | enqueue + marker write, size / MIME / original-name capture, re-pick file reclaim | No |
| **Push** | upload, the commitment boundary, writeback, the gate, payload inlining, `rejected` | **Yes — this is it** |
| **Read / preview** | `MediaResolver`, `media_cache`, lazy download, rendering from disk | No |
| **Delete / discard** | staged-file reclaim on all three document-removal paths | No |
| **Logout / wipe** | `MediaStore.clearAll` | No |
| **Schema** | v6 → v7 `media_cache` | Cross-cutting |

### The corollary worth internalising

**For a fully-online user, the push pipeline's attachment half is inert.** An online pick uploads immediately and stores a real `file_url`; `isLocalAttachmentPath` excludes `/files/` and `/private/files/`, so `queueIfLocalAttachment` never fires, no `pending_attachments` row is ever created, and the gate passes trivially with nothing to resolve.

That means the corruption this release fixes (§4) could **only ever** affect an attachment that was picked while offline or whose inline upload failed transiently. It was never reachable on a purely online device — which is also why it survived so long.

The read path is the mirror image: it is entirely independent of push and runs for **every** document, including ones pulled from the server that this device never created.

---

## 2. The commitment model

Two rules carry the whole design:

> **1. A `server_file_url` committed to SQLite is the correctness boundary.**
> Not the HTTP response — the *committed row*. A url that has been received but not yet written to disk is not a fact the pipeline may rely on.

> **2. Upload and document-push are independent commitments.**
> Once the url is committed, the file is uploaded — permanently — regardless of whether the parent document ever syncs. No later attempt re-uploads it.

Rule 2 is what makes retries safe. Rule 1 is what makes rule 2 implementable: there is a real window between the server committing the file and this device knowing about it, and pretending otherwise is how duplicate uploads happen.

The gap between the two is handled by the server, not the client: Frappe's `save_file` computes `content_hash = md5(content)` and reuses an existing `File` with the same `(content_hash, is_private)` rather than storing a second copy. A retry after a lost response therefore returns the **same** `file_url`. This is why the SDK does **no** client-side hashing or pre-flight lookup — verified against Frappe 16.25.0, 16.26.3 and 17.0.0-dev.

---

## 3. Full lifecycle

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant F as AttachField /<br/>ImageField
    participant P as attachment_pick
    participant S as MediaStore
    participant W as LocalWriter
    participant PE as PushEngine
    participant AP as AttachmentPipeline
    participant FR as Frappe

    U->>F: pick / capture
    F->>P: resolvePickedAttachment
    P->>P: size guard (maxBytes)
    P->>S: stageToOutbox
    S-->>P: outbox/<id>/<name>

    alt online
        P->>FR: upload_file
        FR-->>P: file_url
        P->>S: move staged -> cache/
        Note over P: field stores the file_url
    else offline / transient failure
        Note over P: field stores the STAGED PATH
    end

    U->>W: save
    W->>W: queueIfLocalAttachment
    W->>W: enqueue pending_attachments row
    Note over W: column := pending:<id>

    U->>PE: sync
    PE->>AP: resolveForTopParent (push gate)
    AP->>FR: upload_file (no dt/dn)
    FR-->>AP: file_url
    AP->>AP: recordUpload  ← COMMITMENT BOUNDARY
    AP->>S: moveToCache (idempotent)
    AP->>AP: ONE txn: markDone + writeback + cache index
    Note over AP: column := file_url
    PE->>PE: PayloadAssembler.assemble
    PE->>FR: POST document (real url, no marker)
    FR->>FR: attach_files_to_document relinks the File
```

Steps 1–9 happen at pick time; 10–12 at save; 13–20 at sync. The two upload triggers (pick-time when online, push-time otherwise) are deliberate: immediate upload gives the user a fast error, which for an oversized photo is the difference between retaking it and losing it.

---

## 3a. How the uploaded file is rewired to the real record and field

This is the part with the most moving pieces, because **the upload happens before the document exists**. Three things have to converge: the bytes (a `File` record), the reference (a docfield value), and the ownership link (`File.attached_to_*`).

### Step 1 — the file is uploaded deliberately unattached

`attachment_pipeline::AttachmentPipeline._resolveOne` calls the uploader with **no** `doctype` and **no** `docname`, so the resulting `File` row has all three of `attached_to_doctype`, `attached_to_name` and `attached_to_field` set to `NULL`.

That is not laziness. Two constraints force it:

1. At upload time the parent document does not exist on the server yet — an offline-created record has no `name` until its INSERT lands.
2. Frappe v16's `File` controller rejects `attached_to_doctype` without a non-empty `attached_to_name`, so the SDK cannot even send half the coordinate.

What the server holds at this point is a valid, orphaned `File` whose only identity is its `file_url`.

### Step 2 — the reference reaches the docfield

The pipeline writes the resolved `file_url` back into `docs__<doctype>.<fieldname>` (§4), `PayloadAssembler` picks it up as an ordinary column value, and the document POST carries it like any other string. The server stores it in the docfield exactly as Desk would.

So after the document saves, the server has a docfield holding `/files/photo.jpg` **and** an unattached `File` row whose `file_url` is `/files/photo.jpg`. They are not yet connected.

### Step 3 — Frappe joins them on `on_update`

`frappe/core/doctype/file/utils.py::attach_files_to_document` is registered on `doc_events["*"]["on_update"]` and `["on_update_after_submit"]`, so it runs for **every** doctype. Its logic, in order:

```mermaid
flowchart TD
    A["on_update fires for the document"] --> B["iterate fields where<br/>fieldtype IN (Attach, Attach Image)"]
    B --> C{"value starts with<br/>/files or /private/files ?"}
    C -->|no| SKIP[skip this field]
    C -->|yes| D{"File already exists with this<br/>url + name + doctype + field ?"}
    D -->|yes| SKIP2[already attached — skip]
    D -->|no| E{"File exists with this url and<br/>ALL attached_to_* NULL ?"}
    E -->|yes| F["set attached_to_name / _doctype / _field<br/>+ recompute is_private from the url"]
    E -->|no| G["INSERT a NEW File row<br/>pointing at the same file_url"]

    style F fill:#2d6a4f,color:#fff
    style G fill:#6c584c,color:#fff
```

The match key in step E is the `file_url` **plus** all three `attached_to_*` being NULL. That is precisely the shape the SDK uploads, which is why the unattached upload is the right move rather than a workaround.

Note the two consequences of that final `else`:

- **`is_private` is recomputed from the url prefix during relink**, overriding what the SDK sent. A file uploaded privately that ends up at a `/files/...` url becomes public, and vice versa. The url wins.
- **If no unattached row is left**, stock **inserts a new `File`** pointing at the same `file_url`. So a parent attach field always ends up with a record, even when the url was already claimed. (The child-row hook behaves differently — see step 4.)

One upload always produces one `File` row, even when the bytes are deduped: `save_file` reuses the existing `file_url` and skips writing the blob, but still inserts the record. N uploads of identical bytes therefore give N `File` rows sharing one url and one file on disk — which is exactly what makes the per-row claiming in step 4 work.

### Step 4 — child table rows need a second hook

Stock `attach_files_to_document` reads `doc.meta.get("fields", ...)` — the fields of **the document being saved**. A child table row is a different doctype, and in v16 children persist through raw `db_update()` **without firing lifecycle hooks**. So a child row's `Attach` field is never visited by the stock hook: the file uploads fine, the docfield holds the right url, and the `File` stays orphaned forever.

`mobile_control/attachment_relink.py::relink_mobile_files` closes that. Verified against the installed app:

- Registered on `doc_events["*"]["on_update"]` **and** `["on_update_after_submit"]`, so it is a catch-all like stock's.
- **Fast-exits unless the doc has a `mobile_uuid`**, so non-mobile saves site-wide pay one attribute lookup.
- Walks `doc.meta.get_table_fields()` → each child row → each `Attach` / `Attach Image` field on that child.
- Skips a field already linked to `(url, child.doctype, child.name, fieldname)`, which makes re-saves idempotent.
- Claims **one** unattached `File` per field, `ORDER BY creation ASC LIMIT 1`, matching `attached_to_*` as NULL **or empty string** (stock matches only `None`).
- Writes via `frappe.db.set_value` — a raw UPDATE, so it does not recurse into its own `on_update` registration.

Two behavioural differences from stock worth knowing, both verified in source:

| | Stock (parent fields) | `mobile_control` (child rows) |
|---|---|---|
| No unattached `File` left | **Inserts a new one** | **Skips** — the row stays unlinked |
| `is_private` | **Recomputed** from the url prefix | Left untouched |

The "skip" is why a missing or failed child upload leaves a silent gap rather than a bogus record — but it also means a child row can end up with a correct docfield and no `File` link.

### How N parent fields and X child rows x M fields are identified

Identification happens **twice**, at two different stages, with two different keys. Conflating them is easy and wrong.

#### Stage 1 — the push pipeline, on device: the uuid triple + fieldname

This is where each attachment is matched to its exact slot, and it is done **entirely** with the identifiers the device already holds. `file_url` is the *value being written*, never the key.

| Column | Selects | In code |
|---|---|---|
| `top_parent_uuid` | the **set** of attachments belonging to one outbox row | `findUnresolvedForTopParent` → `where: 'top_parent_uuid = ? AND state != ?'` |
| `parent_doctype` | **which table** — `docs__order` vs `docs__order_item` | `_tableFor(p.parentDoctype)` |
| `parent_uuid` | **which row** in that table | `where: 'mobile_uuid = ?', whereArgs: [p.parentUuid]` |
| `parent_fieldname` | **which column** on that row | `<String, Object?>{p.parentFieldname: resolvedUrl}` |

So for N parent fields and X child rows carrying M each:

```mermaid
flowchart TD
    Q["findUnresolvedForTopParent('P1')<br/>top_parent_uuid = P1"] --> R1["photo<br/>parent_uuid=P1, doctype=Order"]
    Q --> R2["scan<br/>parent_uuid=P1, doctype=Order"]
    Q --> R3["receipt<br/>parent_uuid=C0, doctype=Order Item"]
    Q --> R4["signature<br/>parent_uuid=C0, doctype=Order Item"]
    Q --> R5["receipt<br/>parent_uuid=C1, doctype=Order Item"]
    Q --> R6["... X*M rows total"]

    R1 --> W1["UPDATE docs__order SET photo=url<br/>WHERE mobile_uuid='P1'"]
    R2 --> W2["UPDATE docs__order SET scan=url<br/>WHERE mobile_uuid='P1'"]
    R3 --> W3["UPDATE docs__order_item SET receipt=url<br/>WHERE mobile_uuid='C0'"]
    R4 --> W4["UPDATE docs__order_item SET signature=url<br/>WHERE mobile_uuid='C0'"]
    R5 --> W5["UPDATE docs__order_item SET receipt=url<br/>WHERE mobile_uuid='C1'"]

    style Q fill:#1d3557,color:#fff
```

`top_parent_uuid` is the only thing that makes this **one** operation: it is stamped with the parent's `mobile_uuid` for every attachment at any depth, so a single query gathers the whole set and the push gate can block on all of it together. The other three then disambiguate completely — `(parent_uuid, parent_fieldname)` is unique per queued attachment, which is also the key the re-pick replacement uses.

Note `parent_uuid` is matched against `mobile_uuid` in the target table, **not** against `parent` or a server name. That is what lets the writeback work before the document has ever been to the server: a child row created offline has a `mobile_uuid` and no server identity at all.

Marker resolution in `inlinePayload` is likewise by **row id** (`pending:<id>`), not by url.

#### Stage 2 — the server's relink hook, post-save: `file_url`

None of the four columns above cross the wire — they are device-local identity. So after the document saves, the relink hooks have no way to ask "which field did this file belong to". They re-derive it by **walking the saved document** and reading what each attach field actually holds, matching that value against `File.file_url` where `attached_to_*` is still unset.

That is why the two stages use different keys, and why the SDK's job ends at putting the right url in the right column: once it has done that, the url *is* sufficient for the server to reconstruct the coordinate it needs.

Three properties follow on the server side:

1. **Child identity never has to survive the round trip.** Frappe assigns child `name`s at insert; the device's `C0`/`C1` uuids are irrelevant to relinking. The hook reads each child row *after* it is saved, so it uses the real server name.
2. **Order and reordering do not matter.** Matching is by value, so a child table Frappe renumbers or reorders still relinks correctly.
3. **Shared bytes still resolve one-to-one.** Each upload produces its own `File` row even when the blob is deduped, and a claimed row stops matching the `IS NULL` filter — so the next field gets the next row.

The failure mode to watch on the server side is arithmetic: the hook claims **one `File` per attach field it walks**. Fewer unattached rows than referencing fields leaves the surplus unlinked — which is what the push gate prevents by refusing to push until every attachment is `done`.

### What the SDK guarantees, and what it does not

| Guarantee | Owner |
|---|---|
| The docfield holds a real `file_url`, never a marker | **SDK** — verified by tests |
| The bytes exist on the server before the document POST | **SDK** — the commitment boundary |
| Identical bytes are stored once | **Frappe** — content-hash dedup |
| A parent `Attach` / `Attach Image` field gets its `File` linked | **Frappe** — stock `on_update` hook |
| A child-row attach field gets its `File` linked | **`mobile_control`** — `relink_mobile_files`, one `File` claimed per field |

Two things follow that are worth stating plainly:

- **If `relink_mobile_files` is absent from the target server**, child-row attachments still upload and the docfield still holds the correct url — the file is reachable and renders — but `File.attached_to_*` stays NULL, so Desk's attachment sidebar will not show it and any server-side logic keying on `attached_to_name` will miss it. The SDK cannot detect this.
- **Stock relink covers `Attach` and `Attach Image` only.** Frappe's `Image` fieldtype is conventionally a *display* field that renders whatever the field named in its `options` holds, so it normally carries no url of its own; the SDK nonetheless treats `Image` as an attachment field (`local_writer::kAttachmentFieldTypes`). If you store a url directly in an `Image` field, expect no stock relink for it.

---

## 3b. Many fields: N on the parent, X child rows with M each

A realistic survey form is not one photo. Take **N** attach fields on the parent and **X** child rows carrying **M** each — total **N + (X x M)** attachments for one document. Behaviour is pinned by `test/sync/attachment_multi_field_test.dart` (N=2, M=2, X=3, so 8 attachments).

### One document, one query, one gate

Every row — parent field or child-row field — is stamped with the **top parent's** `mobile_uuid`, while `parent_uuid` stays the row's own. So the identity split is:

| | `parent_uuid` | `parent_doctype` | `top_parent_uuid` |
|---|---|---|---|
| Parent field | `P1` | `Order` | `P1` |
| Child row C0 field | `C0` | `Order Item` | `P1` |
| Child row C2 field | `C2` | `Order Item` | `P1` |

`findUnresolvedForTopParent('P1')` therefore returns all 8 in one query at any nesting depth, and the push gate blocks on the whole set together. `parent_uuid` + `parent_fieldname` is the precise coordinate the writeback uses, so each resolved url lands in its **own** row's column — a child's `receipt` updates `docs__order_item` `WHERE mobile_uuid = 'C0'`, not the parent's table.

The uniqueness key for a queued attachment is `(parent_uuid, parent_fieldname)`. N parent fields produce N rows sharing `parent_uuid = P1` with distinct fieldnames; each child row produces M rows under its own uuid. A re-pick replaces exactly one of them.

### Uploads are serial, and the first failure stops the pass

`resolveForTopParent` is a plain `for` loop with an `await` inside — **not** a `Future.wait`. So:

```mermaid
flowchart LR
    A["photo<br/>done"] --> B["scan<br/>done"] --> C["receipt0<br/>done"] --> D["signature0<br/>done"] --> E["receipt1<br/>FAILS"] --> F["signature1<br/>never attempted"] --> G["receipt2<br/>never attempted"] --> H["signature2<br/>never attempted"]

    style A fill:#2d6a4f,color:#fff
    style B fill:#2d6a4f,color:#fff
    style C fill:#2d6a4f,color:#fff
    style D fill:#2d6a4f,color:#fff
    style E fill:#9d0208,color:#fff
    style F fill:#6c584c,color:#fff
    style G fill:#6c584c,color:#fff
    style H fill:#6c584c,color:#fff
```

`_resolveOne` throws, which aborts the loop. Three consequences, all deliberate:

1. **Progress is never thrown away.** Each attachment commits in its own transaction, so `photo`, `scan`, `receipt0` and `signature0` are already `done` with their columns written back. The document is blocked, not reset.
2. **The rest stay `pending`,** untouched — they were never attempted, so they carry no retry count or error.
3. **The next dispatch finishes the set** and re-uploads nothing that already landed: `done` rows are outside `findUnresolvedForTopParent`, and a row holding a committed `server_file_url` skips the upload entirely.

That is why total upload count across a recovered document is *(attempts on the failing item)* + *(one per attachment that had not yet succeeded)* — never one per attachment per dispatch.

### Cost, and where it bites

- **N + (X x M) sequential round trips.** 20 photos are 20 uploads, one after another. There is no parallelism and no batching; a slow link multiplies.
- **A transient failure costs its full backoff before the loop aborts** — with the default `[2s, 5s, 10s]` that is 2s + 5s of waiting across 3 attempts, and the attachments behind it wait for all of it before being deferred to the next dispatch.
- **One rejected attachment out of fifty blocks the document indefinitely.** That is the gate working as designed — the document cannot be represented faithfully without that file — but the error must identify *which* one, which is why `BlockedByUpstream` carries the file and field rather than a row id.

### Identical bytes in several fields

If the same photo is attached to M fields, each gets its own `pending_attachments` row and its own upload call — the SDK does not deduplicate client-side. Frappe's content-hash dedup then returns the **same** `file_url` for all of them, so:

- one set of bytes on the server,
- one `media_cache` entry on the device (keyed by url; the second `moveToCache` finds the destination present, reports success, and discards its now-redundant staged copy),
- and **one `File` record per field** — one per upload — which is precisely what lets each field claim its own during relink (§3a, step 4).

So the wasted work is upload bandwidth, not storage on either side.

---

## 4. Resolution mechanism

Three layers, each covering what the one before it cannot.

```mermaid
flowchart TD
    A[upload succeeds] --> B[recordUpload commits server_file_url]
    B --> C[move staged bytes to cache/]
    C --> D["ONE txn:<br/>markDone + writeback + media_cache insert"]
    D --> E[column holds a real file_url]
    E --> F[PayloadAssembler reads an ordinary value]

    B -. crash .-> G[next dispatch: url committed<br/>-> skip upload, resume at step 3]
    D -. not atomic .-> H[widened query resolves<br/>from the recorded url]
    F -. should be unreachable .-> I[inlinePayload THROWS]

    style B fill:#2d6a4f,color:#fff
    style D fill:#1d3557,color:#fff
    style I fill:#9d0208,color:#fff
```

**1. Writeback (primary).** After `markDone`, the resolved `file_url` replaces the marker in `docs__<doctype>`. The marker ceases to exist the moment it is resolved, so payload assembly reads a normal value and the entire bug class disappears — including the auto-merge path, where `ThreeWayMerge` would otherwise carry the marker forward.

The three writes — `markDone`, the writeback, and the `media_cache` insert — are **one transaction**, so the column and the row can never disagree. It runs through the doctype's `WriteQueue` when the host wires one, matching the other two `docs__` writers in `push_engine` (`ResponseWriteback` and the auto-merge persist). Writing outside that queue would race them.

**2. Widened query (backstop).** `pending_attachment_dao::PendingAttachmentDao.findUnresolvedForTopParent` returns every row that is not `done`; `findAllForTopParent` feeds the resolution map, so a marker left by an interrupted writeback still resolves from the already-recorded url. Given the atomic transaction above this should be unreachable — a hit means the atomicity assumption broke.

**3. Hard failure (assertion).** `AttachmentPipeline.inlinePayload` **throws** on an unresolved marker. Previously it passed the marker through, which is exactly how the literal string `pending:42` was written into Frappe as an attach-field value, indistinguishable from a real one.

### The push gate

> **A document may only push when every one of its attachments is `done`.**

Anything else throws `BlockedByUpstream` carrying the file and field name — not a row id, which a user cannot act on. There is no path where a push proceeds with an unresolved attachment.

---

## 5. State machine

```mermaid
stateDiagram-v2
    [*] --> pending: enqueue at save
    pending --> uploading: markUploading
    uploading --> done: upload OK + txn
    uploading --> failed: transient exhausted
    uploading --> rejected: terminal refusal
    failed --> uploading: next dispatch<br/>(auto re-armed)
    done --> [*]: only wipe or doc delete
    rejected --> [*]: replaced by a re-pick

    note right of failed
        network, timeout, 5xx.
        Blocks this push, retried
        on the next one.
    end note

    note right of rejected
        oversized, wrong type,
        not permitted. NEVER
        auto-retried.
    end note
```

The `failed` / `rejected` split is load-bearing. Without it, re-arming failed rows would retry a permanently unuploadable file — an oversized photo, say — on every push forever. It mirrors the outbox's own `failed` / `paused` distinction.

**Replacing a rejected attachment creates a new operation.** A re-pick deletes the old row *and its staged file* and inserts a fresh `pending` one (`local_writer::queueIfLocalAttachment`), so it never inherits a stale retry count or error. A rejected row is never resurrected in place.

---

## 6. Storage layout

```
<appDocuments>/mform_attachments/
├── outbox/
│   └── <uuid>/<original filename>   ← staging. NEVER evictable.
└── cache/
    └── <sha256(file_url)><ext>      ← content store. Evictable, wiped on logout.
```

Two directories because staging and cache have **opposite** safety properties: an un-uploaded staged file is the only copy of those bytes in existence, while a cached download is always re-fetchable.

**Why staging uses a directory per pick.** The file keeps the name the user chose; uniqueness comes from the generated parent directory. The original filename has no other route to the server — it does not fit through the field's `onChanged`, and renaming to `<uuid><ext>` destroyed it at pick time, which is why every 2.0-beta upload landed server-side as an opaque uuid.

**Why the cache is keyed by `file_url`.** Frappe dedupes by content hash and returns the same url for identical bytes, so two documents can legitimately share one file. Keying per-document would store those bytes twice and turn deletion into a reference-counting problem. Keyed by url there is exactly one copy and the question never arises.

### The filesystem/SQLite boundary

There is **no transaction spanning the two**, and the design does not pretend otherwise. The step order makes every divergence self-healing:

| Divergence | Consequence |
|---|---|
| Cache file with no `media_cache` row | Invisible orphan bytes. Harmless. |
| `media_cache` row with no file | A cache **miss**. Re-fetches. |

Neither is an error, because cache content is non-authoritative by construction. And because `recordUpload` commits first, a crash anywhere after it resumes on the next dispatch instead of re-uploading.

---

## 7. Data model

### `pending_attachments` — the upload queue

Transient work items: `enqueue` → `uploading` → `done` / `failed` / `rejected`.

| Column | Notes |
|---|---|
| `parent_uuid`, `parent_doctype`, `parent_fieldname` | which field on which row |
| `top_parent_uuid` | the outbox row's `mobile_uuid`; child-row attachments carry the **parent's** uuid so one query finds them all |
| `local_path` | absolute staged path |
| `file_name` | the user's ORIGINAL filename |
| `mime_type`, `size_bytes` | derived at save time from the staged file |
| `server_file_url`, `server_file_name` | the commitment boundary |
| `state`, `retry_count`, `error_message` | see §5 |

### `media_cache` — the content store (new in this release)

| Column | Notes |
|---|---|
| `file_url` | **PRIMARY KEY** — one copy per url, however many docs reference it |
| `local_path` | `cache/<sha256(file_url)><ext>` |
| `size_bytes`, `mime_type`, `is_private` | |
| `source` | `uploaded` (this device made it) / `downloaded` (fetched for preview) |
| `created_at`, `last_accessed_at` | `last_accessed_at` is written now and consumed by Phase 2's LRU |

Schema **v6 → v7** (`app_database::_migrateV6ToV7`). Nothing is backfilled: an empty cache table simply means every lookup is a miss and re-fetches on demand.

**Document deletion never touches the cache.** Deleting a document clears its upload-queue rows and staged files; cached bytes are pure performance state governed by eviction and wipe only. That is what lets eviction be deferred without leaving a correctness hole.

---

## 8. Case matrix

Every case is resolved by the two rules in §2. All are covered by tests in `test/sync/attachment_pipeline_cases_test.dart`, which assert the uploader **call count** — "no duplicate uploads" is a claim about invocations, not just outcomes.

| # | What happens | Row state | Behaviour | Re-upload? |
|---|---|---|---|---|
| 1 | All succeeds | `done` + url | — | No |
| 2 | Upload OK, crash before the txn | `uploading` + url | url committed → skip upload, resume | No |
| 3 | Upload OK, **response lost** | `uploading`, no url | Re-uploads; Frappe dedup returns the **same** url | No duplicate bytes or logical attachment |
| 4 | Crash between commit and writeback | `uploading` + url | Next dispatch resumes the move + txn | No |
| 5 | Upload OK, **parent push fails** | `done` | Column holds the real url; retry does no attachment work | No |
| 6 | Upload terminally refused | `rejected` | Push gate blocks with a named reason | Nothing was uploaded |
| 6b | Upload fails transiently | `failed` | Auto-retried next dispatch | Nothing was uploaded |
| 7 | Document deleted / discarded | rows + staged files gone | Server keeps an orphaned unattached `File` | — |
| 8 | Re-pick before sync | prior row + file gone | Prior upload (if any) orphaned server-side | — |
| 9 | Same file on two fields | two rows | Frappe dedupes bytes; both relink | No duplicate bytes |

**Case 3 is the one no client-side guard can solve** — a lost response is indistinguishable from a failure. The server's content-hash dedup covers it.

**Cases 7 and 8 leave orphaned unattached `File` rows server-side.** Frappe has no GC for these (its `attach_files_to_document` hook *attaches*, it does not collect). This release deliberately ignores that and records it as a `mobile_control` concern: the SDK deleting server `File` records it can no longer prove ownership of is riskier than a few orphan rows.

---

## 9. Error classification

`attachment_error_classifier::isTerminalAttachmentError` decides `failed` vs `rejected`, grounded in what the upload path actually raises (`rest_helper::RestHelper._handleResponse`).

| Error | Class | Why |
|---|---|---|
| `ValidationException` (417) | **terminal** | how `MaxFileSizeReachedError` arrives |
| `AuthException` 403 | **terminal** | this user may not upload here |
| `AuthException` 401 | transient | credential expired; refresh fixes it |
| 4xx other than 408/429 | **terminal** | client error, will repeat identically |
| 408, 429, 5xx | transient | may clear |
| `NetworkException` | transient | transport |
| anything unrecognised | transient | see below |

**Unrecognised errors default to transient.** A wrongly-transient error costs one retry; a wrongly-terminal one strands the user's file with no automatic recovery. Fail toward retrying.

### Failures that are deliberately not errors

- **Cache move fails** → the upload still succeeded (rule 1). The staged copy is reclaimed, since the bytes are on the server and nothing else would revisit an `outbox/` file once its row is `done`.
- **Step-4 transaction fails** → logged, never rethrown. The url is committed, so reporting failure would contradict rule 2.
- **Cached file missing** → a miss, re-fetched.
- **Preview download fails** → placeholder. A media fetch must never break form rendering.
- **Wipe during an in-flight upload** → the row is gone, so the response is discarded. No locking.

---

## 10. Read path

One function serves every value form, both field widgets, and both phases (`media_resolver::MediaResolver.resolve`):

```mermaid
flowchart TD
    V[field value] --> M{"starts with<br/>pending: ?"}
    M -->|yes| SP["staged path from<br/>pendingAttachmentPaths"]
    M -->|no| C{"media_cache hit<br/>AND file exists?"}
    C -->|yes| L[local path<br/>+ touch last_accessed_at]
    C -->|no| O{online?}
    O -->|yes| FE[fetch -> store in cache -> return]
    O -->|no| PH[null -> placeholder]

    style SP fill:#2d6a4f,color:#fff
    style L fill:#2d6a4f,color:#fff
    style FE fill:#1d3557,color:#fff
    style PH fill:#6c584c,color:#fff
```

A `pending:` value is **never** fetched over HTTP, even when malformed — it is local identity, not a url, and falling through to the network would turn a row id into a request path.

Consequences:

- `ImageField` renders from disk via `Image.file` when a cached copy exists, instead of `Image.network`. That is what makes a pulled document's image visible offline.
- `AttachField` hands `OpenFilex` a cached path instead of re-downloading on every open — which also removes the stale-bytes hazard the old temp-download path carried.
- Anything viewed once while online stays viewable offline. Phase 2's background prefetch is then a pure optimisation, not the thing that makes offline preview work.

**Labels never come from the resolved path.** The cache names files `sha256(file_url)`, so a label routed through it would read as 64 hex characters instead of `report.pdf`. Labels derive from the stored value; only the *view target* is resolved.

**The widgets depend on a `ResolveMediaFn` function**, not on `MediaResolver` itself — hosts pass `resolver.resolve`. That keeps the UI layer off the DAO/filesystem stack, which also makes the widgets testable: widget tests run in a fake-async zone where real sqflite and `dart:io` futures never complete.

**The resolve future is memoised per value** (`media_resolve_builder::MediaResolveBuilder`). Starting it inside `build` creates a new future on every rebuild, and each completion triggers another — an infinite loop that re-reads the cache and can re-download indefinitely.

---

## 11. Security and lifetime

Cached media includes files uploaded with `is_private = 1` (the default).

`FrappeSDK.logout(clearDatabase: true)` now calls `MediaStore.clearAll()`. Before this release the store survived logout entirely: `AppDatabase.clearAllData()` drops `pending_attachments` and `media_cache`, but the **files live outside SQLite**, so on a shared device one user's private survey photos stayed readable after the next sign-in.

The wipe is **destructive by design** — it also clears `outbox/`, which holds the only copy of any attachment that never uploaded.

---

## 12. Host API

| Member | Purpose |
|---|---|
| `FrappeSDK.mediaStoreSize()` | total bytes on disk (staged + cached) |
| `FrappeSDK.clearMediaCache()` | clear the store — **destructive**, put it behind a confirmation |
| `kDefaultMaxAttachmentBytes` | 10 MB, matching Frappe's stock `max_file_size`. **Not host-overridable yet** — see §13 |
| `AttachmentTooLargeException` | thrown at pick, carries `sizeBytes` and `limitBytes` |
| `attachmentTooLargeMessage(e)` | user-facing message naming the real limit |
| `ResolveMediaFn` | what the field widgets accept; pass `resolver.resolve` |

The size guard runs **before** the durable copy is made, so an oversized pick never occupies disk. A file that cannot be stat'd skips the guard rather than being refused — failing to measure is not evidence of being too large.

---

## 13. Limitations

- **Media storage is unbounded until logout.** There is no automatic eviction in this release. `size_bytes` and `last_accessed_at` are populated from day one so Phase 2's policy has real data, and `mediaStoreSize()` / `clearMediaCache()` exist so a host can expose usage and a manual clear meanwhile.
- **No compression.** `pickImage` is called with no `imageQuality` / `maxWidth` / `maxHeight`, so a capture is full-resolution — 3–12 MB on a current phone. Frappe strips EXIF server-side and accepts `optimize` / `max_width` / `max_height` on `upload_file`, none of which the SDK sends yet.
- **No background prefetch.** Media for a pulled document is cached on first view, not ahead of time.
- **An ONLINE pick does not populate the cache.** `resolvePickedAttachment` deletes the staged copy after a successful inline upload rather than moving it into `cache/`, so a photo taken while online is uploaded and its local bytes discarded — previewing it later costs a download. Only the **push** path (offline pick, or a transient-failure fallback) promotes bytes into the cache via `moveToCache`. Closing this is a small change in the pick path, not a design change: the bytes, the url and the store are all already in hand at that point.
- **The size limit is not host-configurable.** `kDefaultMaxAttachmentBytes` (10 MB) is the default for `resolvePickedAttachment`'s `maxBytes`, but the only callers are this SDK's own `AttachField` / `ImageField` and neither exposes an override. A deployment whose System Settings `max_file_size` differs will either refuse files the server would have accepted, or accept files it will reject at upload (which the pipeline then handles correctly as a terminal rejection — the document blocks with a named reason rather than corrupting). Making it configurable means threading a parameter through `FormScreen` -> `FormBuilder` -> `FieldFactory`, the same path `mediaResolver` takes.
- **Child-row relinking depends on `mobile_control`.** See §3.
- **Orphaned server `File` rows** after a delete or re-pick are not collected. See §8.
- **Not verified on a device.** The platform pickers, camera lost-capture recovery, `OpenFilex` handoff and the real logout wipe are covered by no automated test in this repo.

---

## 14. Where the code lives

| Concern | File |
|---|---|
| Pick, size guard, terminal/transient split | `lib/src/utils/attachment_pick.dart` |
| Two-directory store, idempotent move | `lib/src/utils/media_store.dart` |
| Marker helpers, fetch-url builder, MIME | `lib/src/utils/attachment_paths.dart` |
| Upload queue | `lib/src/database/daos/pending_attachment_dao.dart` |
| Content store index | `lib/src/database/daos/media_cache_dao.dart` |
| Push gate, writeback, inlining | `lib/src/sync/attachment_pipeline.dart` |
| Terminal/transient classifier | `lib/src/sync/attachment_error_classifier.dart` |
| Save-time enqueue + marker write | `lib/src/services/local_writer.dart` |
| Preview resolution + lazy cache | `lib/src/services/media_resolver.dart` |
| Memoised resolve for widgets | `lib/src/ui/widgets/fields/media_resolve_builder.dart` |
| Upload endpoint fields | `lib/src/api/attachment_service.dart` |

---

## 15. Test coverage

Where to look when changing any of this, and what each file is protecting.

| Test | Pins |
|---|---|
| `test/sync/marker_resolution_regression_test.dart` | The three marker-corruption paths (§8 cases 1–6b). Began as repros asserting the **bug**; the inverted assertions are the proof of the fix. |
| `test/sync/attachment_pipeline_cases_test.dart` | The case matrix, asserting uploader **call counts** — "no duplicate uploads" is a claim about invocations. |
| `test/sync/attachment_multi_field_test.dart` | N parent + X child rows x M fields: one-query fan-out, per-row writeback targets, serial-failure semantics, resume without re-upload (§3b). |
| `test/sync/attachment_error_classifier_test.dart` | terminal vs transient, per exception type and status (§9). |
| `test/sync/attachment_pipeline_test.dart` | Backoff, the H3 no-re-upload guard, `inlinePayload` including the **throw** on an unresolved marker. |
| `test/sync/attachment_pipeline_cleanup_test.dart` | Staged copy leaves `outbox/` on success — and is still reclaimed when the cache move fails. |
| `test/sync/attachment_pipeline_child_discovery_test.dart` | Child-row attachments are found via `top_parent_uuid`. |
| `test/sync/offline_attachment_e2e_test.dart` | Multi-marker resolution into the right slots. |
| `test/services/attachment_file_reclaim_test.dart` | `deleteForTopParent` removes files with rows, spares other documents, and **never touches the cache**. |
| `test/services/media_resolver_test.dart` | All four resolution branches, self-healing on a missing file, and that a `pending:` value is never fetched over HTTP. |
| `test/services/media_wipe_test.dart` | Logout clears staged **and** cached media; `storeSizeBytes` counts nested staged files. |
| `test/services/local_writer_attachments_test.dart` | Marker write, no double-enqueue on re-save, and that size / MIME / **original filename** are recorded. |
| `test/utils/media_store_test.dart` | Directory layout, deterministic cache paths, idempotent `moveToCache`, collision safety. |
| `test/utils/attachment_pick_test.dart` | Size guard before staging, and the terminal-vs-transient split at pick time. |
| `test/utils/attachment_paths_test.dart` | Marker parsing and local-path classification. |
| `test/utils/attachment_storage_test.dart` | The legacy `copyToAttachmentStore` entry point still lands in `outbox/`. |
| `test/database/media_cache_migration_test.dart` | v6 → v7, idempotently, with `file_url` as the primary key. |
| `test/database/daos/media_cache_dao_test.dart` | Upsert-not-duplicate, `touch`, `totalBytes` tolerating NULL sizes. |
| `test/database/daos/pending_attachment_dao_test.dart` | `findUnresolved` returns every non-done state — including `rejected`, which must still block. |
| `test/api/attachment_service_test.dart` | The `doctype` / `docname` / `file_name` keys, and that the multipart part carries the **original** filename. |

**What no test in this repo covers**, and therefore has to be checked on a device: the platform file and image pickers, camera lost-capture recovery, `OpenFilex` handoff of a cached file, real `path_provider` paths, and whether `mform_attachments/` is actually gone after a logout. The Frappe-side contract in §3a is verified against three Frappe checkouts' **source**, not against a running site.
