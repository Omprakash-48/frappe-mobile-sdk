/// A snapshot of on-device attachment media usage.
///
/// [orphanBytes] is a SUBSET of [outboxBytes] — reclaimable staged files are
/// still staged files. It is deliberately excluded from [totalBytes] so a
/// caller cannot double-count them.
class MediaStoreUsage {
  /// Staged, not yet uploaded. Correctness storage: the only copy.
  final int outboxBytes;

  /// Uploaded or downloaded content. A performance copy; always re-fetchable.
  final int cacheBytes;

  /// How much of [outboxBytes] a sweep would reclaim right now.
  final int orphanBytes;

  /// How many files that is.
  final int orphanCount;

  /// Attachments downloaded only so the device's default app could open them,
  /// held under the OS temp root rather than the media store.
  ///
  /// Reported separately because nothing reference-counts it: it is wiped as a
  /// unit, never file-by-file by the orphan sweep — so it contributes nothing to
  /// [orphanBytes] even though all of it is reclaimable.
  ///
  /// Reclaimed by `clearMediaCache()` and by `logout(clearDatabase: true)`. It
  /// is counted in [totalBytes], so a host showing that figure next to a
  /// "Clear cached media" control will see the number actually move.
  ///
  /// Optional with a default so adding it did not break a caller constructing
  /// this.
  final int viewerTempBytes;

  const MediaStoreUsage({
    required this.outboxBytes,
    required this.cacheBytes,
    required this.orphanBytes,
    required this.orphanCount,
    this.viewerTempBytes = 0,
  });

  /// Every byte this device is holding for attachments. [viewerTempBytes] is
  /// included because it is real occupied space — it was omitted while the
  /// viewer cache was invisible to the store, which under-reported usage.
  int get totalBytes => outboxBytes + cacheBytes + viewerTempBytes;

  @override
  String toString() =>
      'MediaStoreUsage(outbox: $outboxBytes, cache: $cacheBytes, '
      'viewerTemp: $viewerTempBytes, '
      'orphan: $orphanBytes in $orphanCount files)';
}
