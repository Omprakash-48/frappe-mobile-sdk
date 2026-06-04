// Pre-flight manifest types for `/sync_details` (#49). The SDK posts the
// INCREMENTAL doctypes it is about to pull (each with its own `since`
// watermark) and uses the response to skip no-op pulls.

/// One doctype's entry in the `/sync_details` manifest.
class SyncDetailsEntry {
  final String doctype;
  final bool changed;
  final int count;
  final bool metaBumped;

  const SyncDetailsEntry({
    required this.doctype,
    required this.changed,
    this.count = 0,
    this.metaBumped = false,
  });

  factory SyncDetailsEntry.fromJson(Map<String, dynamic> j) => SyncDetailsEntry(
    doctype: (j['doctype'] ?? '').toString(),
    changed: j['changed'] == true,
    count: j['count'] is int ? j['count'] as int : 0,
    metaBumped: j['meta_bumped'] == true,
  );
}

class SyncDetailsResponse {
  /// Keyed by doctype.
  final Map<String, SyncDetailsEntry> entries;
  final int deleteSignals;

  const SyncDetailsResponse({required this.entries, this.deleteSignals = 0});

  factory SyncDetailsResponse.fromJson(Map<String, dynamic> j) {
    final entries = <String, SyncDetailsEntry>{};
    final list = j['doctypes'];
    if (list is List) {
      for (final raw in list) {
        if (raw is Map) {
          final e = SyncDetailsEntry.fromJson(Map<String, dynamic>.from(raw));
          if (e.doctype.isNotEmpty) entries[e.doctype] = e;
        }
      }
    }
    final ds = j['delete_signals'];
    return SyncDetailsResponse(
      entries: entries,
      deleteSignals: ds is int ? ds : 0,
    );
  }
}

/// Doctypes safe to skip this pull: present in [eligible], reported by the
/// manifest as `changed == false` AND `metaBumped == false`. A doctype absent
/// from the manifest, or reported changed/meta-bumped, is always pulled.
Set<String> doctypesToSkip(Set<String> eligible, SyncDetailsResponse manifest) {
  final skip = <String>{};
  for (final dt in eligible) {
    final e = manifest.entries[dt];
    if (e != null && !e.changed && !e.metaBumped) skip.add(dt);
  }
  return skip;
}
