import '../database/field_type_mapping.dart';
import '../database/schema/system_columns.dart';
import '../models/doc_type_meta.dart';
import 'cursor.dart';

/// One page of raw rows from a remote list endpoint, plus how much of the
/// requested window the endpoint actually consumed to produce them.
///
/// [namesScanned] exists because the two wired endpoints differ. Plain
/// `frappe.client.get_list` returns every row it lists, so `rows.length` IS the
/// window consumed and [namesScanned] is null. `listFullDocs` instead lists
/// names and then resolves them through a per-doc permission gate that silently
/// drops denied/missing names, so it can consume 100 names and return 40 docs —
/// or 0. Reporting the name count is what lets [PullPageFetcher] advance the
/// offset by rows *scanned* rather than rows *returned*, and lets it tell
/// "this page was filtered out" apart from "there are no more rows".
class ListHttpPage {
  final List<Map<String, dynamic>> rows;

  /// Candidate rows consumed from the requested window, when that can exceed
  /// `rows.length`. Null means "same as `rows.length`" (the plain path).
  final int? namesScanned;

  const ListHttpPage(this.rows, {this.namesScanned});
}

typedef ListHttpFn =
    Future<ListHttpPage> Function(String doctype, Map<String, Object?> params);

class PullPageResult {
  final List<Map<String, dynamic>> rows;

  /// Cursor advanced past everything this page covered — the next call should
  /// resume strictly after it. On a genuinely empty page, equals the input
  /// cursor; on a fully-filtered page (see [pageFiltered]) it advances past the
  /// scanned window even though [rows] is empty.
  final Cursor advancedCursor;

  /// True when [rows] is empty but the endpoint DID consume candidate rows —
  /// i.e. every name on this page was dropped by the server's per-doc
  /// permission gate (or deleted mid-pull). Such a page is emphatically NOT
  /// end-of-stream, and treating it as one is silent data loss: the pull would
  /// stop here and mark the doctype fully drained with later pages never
  /// fetched. [PullEngine] skips past it instead.
  final bool pageFiltered;

  const PullPageResult({
    required this.rows,
    required this.advancedCursor,
    this.pageFiltered = false,
  });
}

/// One-page list fetch with dual-mode pagination. Spec §5.1.
///
/// **Initial sync** (`cursor.complete == false`): uses `limit_start` offset
/// pagination — no `modified` filter, `limit_start` advances by `pageSize`
/// each page. This guarantees the full dataset is fetched before the cursor
/// is committed, avoiding the seam-skip risk of applying `modified >=` while
/// new records can still land behind the advancing watermark.
///
/// **Incremental sync** (`cursor.complete == true`): uses the classic
/// `modified >= cursor.modified` predicate with `limit_start = 0`. Combined
/// with `order_by modified asc, name asc` this returns:
///   - the seam row(s) at `modified == cursor.modified` — idempotently
///     re-applied by PullApply's UPSERT-by-server_name
///   - all rows with `modified > cursor.modified`
///
/// **Stall hazard (incremental only):** when many rows share the same
/// `modified` second, `modified >= cursor.modified` keeps returning the same
/// page. [PullEngine] owns the stall guard for this case (it only fires for
/// `complete == true` pages). For initial sync the loop terminates on an
/// empty page, so no stall guard is needed.
class PullPageFetcher {
  final ListHttpFn listHttp;

  PullPageFetcher({required this.listHttp});

  Future<PullPageResult> fetch({
    required String doctype,
    required DocTypeMeta meta,
    required Cursor cursor,
    required int pageSize,
  }) async {
    final fields = _fieldsToRequest(meta);
    final params = <String, Object?>{
      'fields': fields,
      'order_by': 'modified asc, name asc',
      'limit_page_length': pageSize,
      'limit_start': cursor.complete ? 0 : cursor.start,
    };

    if (cursor.complete && cursor.modified != null) {
      // Incremental: single-predicate form `modified >= cursor.modified`.
      // Seam row at cursor.modified is re-applied idempotently by PullApply.
      params['filters'] = <List<Object?>>[
        ['modified', '>=', cursor.modified],
      ];
    }
    // Initial sync (complete=false): no filter, offset advances via limit_start.

    final page = await listHttp(doctype, params);
    final rows = page.rows;
    // Offset must advance by what the endpoint CONSUMED, not by what it
    // returned. Advancing by rows.length on the listFullDocs path under-advances
    // whenever the permission gate drops names, re-requesting an ever-growing
    // overlap on the heaviest endpoint in the SDK.
    final scanned = page.namesScanned ?? rows.length;

    if (rows.isEmpty) {
      if (scanned == 0 || cursor.complete) {
        // Genuinely drained — or incremental mode, where limit_start is always 0
        // so there is no offset to skip forward with. Signalling end-of-stream
        // is correct and idempotent there: the cursor simply stays put.
        return PullPageResult(rows: rows, advancedCursor: cursor);
      }
      // Initial mode, every name on this page filtered out. Step the offset past
      // the scanned window and let the engine keep draining.
      return PullPageResult(
        rows: rows,
        advancedCursor: Cursor(
          modified: cursor.modified,
          name: cursor.name,
          complete: false,
          start: cursor.start + scanned,
        ),
        pageFiltered: true,
      );
    }

    final max = _maxRow(rows);

    final Cursor next;
    if (cursor.complete) {
      // Incremental: advance to the page's high-water mark.
      next = Cursor(
        modified: max['modified'] as String?,
        name: max['name']?.toString(),
        complete: true,
      );
    } else {
      // Initial sync: advance offset; track modified/name for the final cursor
      // that markComplete() will persist after the full drain.
      next = Cursor(
        modified: max['modified'] as String?,
        name: max['name']?.toString(),
        complete: false,
        start: cursor.start + scanned,
      );
    }
    return PullPageResult(rows: rows, advancedCursor: next);
  }

  /// The page's maximum `(modified, name)` — its true high-water mark.
  ///
  /// Deliberately NOT `rows.last`. The dual-mode contract documented above
  /// assumes the response arrives in `modified asc, name asc`. That holds for
  /// plain `get_list`, but `listFullDocs` resolves its name list through a bulk
  /// `names in (...)` fetch and nothing in the request obliges the server to
  /// preserve the requested order. Taking the max makes the watermark correct
  /// regardless of endpoint ordering.
  ///
  /// The failure this prevents is not merely a redundant overlap: if a scrambled
  /// `rows.last` happens to carry the page's MINIMUM `modified` — equal to the
  /// incoming cursor — [PullEngine]'s stall guard fires and persists the cursor
  /// at that minimum. The server's ordering is deterministic for the same query,
  /// so the next sync reproduces it and breaks again on the first iteration,
  /// pinning the doctype's watermark permanently.
  static Map<String, dynamic> _maxRow(List<Map<String, dynamic>> rows) {
    var best = rows.first;
    for (final r in rows.skip(1)) {
      if (_compareByModifiedThenName(r, best) > 0) best = r;
    }
    return best;
  }

  /// Orders two rows the same way `order_by: 'modified asc, name asc'` does.
  /// Frappe timestamps are fixed-width `YYYY-MM-DD HH:MM:SS[.ffffff]`, so a
  /// lexicographic compare is a chronological compare. A null `modified` sorts
  /// lowest, so it can only win when every row on the page lacks one.
  static int _compareByModifiedThenName(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final byModified = (a['modified'] as String? ?? '').compareTo(
      b['modified'] as String? ?? '',
    );
    if (byModified != 0) return byModified;
    return (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? '');
  }

  /// Fields to request from `frappe.client.get_list`. Always includes
  /// `name` + `modified` and Frappe's server-owned audit fields (system
  /// identifiers); plus every persisted fieldname (skipping
  /// layout/break/button types). Child-table fields are included so Frappe
  /// expands them inline.
  ///
  /// `owner` / `creation` / `modified_by` are real columns on every DocType
  /// table (never declared in `meta.fields`), so they must be requested
  /// explicitly or `PullApply` would persist NULL and any offline filter on
  /// them would match nothing. `listableFieldnamesForStar` already sends the
  /// same three to this endpoint for wildcard expansion.
  static List<String> _fieldsToRequest(DocTypeMeta meta) {
    final set = <String>{'name', 'modified', ...serverAuditColumnNames};
    for (final f in meta.fields) {
      final t = f.fieldtype;
      final n = f.fieldname;
      if (n == null) continue;
      if (t == 'Table' || t == 'Table MultiSelect') {
        set.add(n);
        continue;
      }
      if (sqliteColumnTypeFor(t) != null) set.add(n);
    }
    return set.toList();
  }
}
