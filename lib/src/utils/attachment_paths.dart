/// Classifies an attach-field value as a durable local file that still needs
/// to be uploaded.
///
/// Returns `true` only for a non-empty string that is a local filesystem path
/// — i.e. NOT already a Frappe server file URL and NOT a `pending:<id>` marker
/// left by the save-time enqueue. The `pending:` exclusion is essential: it
/// stops a re-save of an unsynced document from re-classifying an
/// already-queued field as a fresh local file and enqueueing garbage.
bool isLocalAttachmentPath(Object? value) {
  if (value is! String) return false;
  final p = value.trim();
  if (p.isEmpty) return false;
  const nonLocalPrefixes = [
    '/files/',
    '/private/files/',
    '/api/method/',
    'http://',
    'https://',
    'pending:',
  ];
  for (final prefix in nonLocalPrefixes) {
    if (p.startsWith(prefix)) return false;
  }
  return true;
}

/// Prefix marking a field value whose file is queued in `pending_attachments`
/// but not yet uploaded. Written by the save-time producer; resolved to a real
/// `file_url` by the push pipeline's `inlinePayload`.
const String kPendingMarkerPrefix = 'pending:';

/// Parses the numeric id out of a `pending:<id>` marker, or null if [value]
/// is not a well-formed marker.
int? parsePendingMarkerId(Object? value) {
  if (value is! String) return null;
  final p = value.trim();
  if (!p.startsWith(kPendingMarkerPrefix)) return null;
  return int.tryParse(p.substring(kPendingMarkerPrefix.length));
}

/// Resolves an attach/image field value to the source used for PREVIEW only.
///
/// A `pending:<id>` marker maps to its durable local file via [pendingPaths]
/// (id → local path); if the id is unknown (file gone / map stale) the result
/// is null and the caller shows a broken-image placeholder while keeping the
/// marker as the stored value. Any other value (server URL or local path) is
/// returned unchanged. The stored/submitted field value is NEVER changed by
/// this — display resolution must not leak into the marker/inlinePayload
/// contract.
String? attachmentDisplaySource(Object? value, Map<int, String>? pendingPaths) {
  if (value is! String) return null;
  final p = value.trim();
  if (p.isEmpty) return null;
  final id = parsePendingMarkerId(p);
  if (id != null) return pendingPaths?[id];
  return p;
}
