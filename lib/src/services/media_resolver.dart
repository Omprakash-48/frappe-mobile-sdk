import 'dart:io';

import '../database/daos/media_cache_dao.dart';
import '../models/media_cache_entry.dart';
import '../utils/attachment_paths.dart';
import '../utils/media_store.dart';
import '../utils/sdk_log.dart';

/// Fetches the bytes behind a server `file_url`.
///
/// Returns null on any failure — a media fetch must never break form
/// rendering, so the resolver degrades to a placeholder instead.
typedef MediaFetchFn = Future<List<int>?> Function(String fileUrl);

/// Resolves a stored attach-field value to a local path for DISPLAY, or null
/// when it cannot be shown (offline miss, unknown marker, failed fetch).
///
/// [MediaResolver.resolve] satisfies this signature, so hosts pass
/// `resolver.resolve` directly. Field widgets depend on this function rather
/// than on [MediaResolver] itself: it keeps the UI layer off the DAO/filesystem
/// stack, which matters because widget tests run in a fake-async zone where
/// real sqflite and dart:io futures never complete.
typedef ResolveMediaFn =
    Future<String?> Function(String value, {Map<int, String>? pendingPaths});

/// Resolves an attach-field value to a local path for DISPLAY.
///
/// The stored field value is never modified here. Display resolution must not
/// leak into the marker / `inlinePayload` contract: a `pending:<id>` value
/// stays a marker until the push pipeline uploads it and writes back the real
/// `file_url`.
class MediaResolver {
  final MediaCacheDao cache;
  final MediaFetchFn fetch;
  final bool Function() isOnline;

  MediaResolver({
    required this.cache,
    required this.fetch,
    required this.isOnline,
  });

  /// Resolution order:
  ///
  ///   `pending:<id>` -> staged path (this device, not yet uploaded)
  ///   `<file_url>`   -> cache hit  -> local path
  ///                  -> miss + online  -> fetch, store, return
  ///                  -> miss + offline -> null (caller shows a placeholder)
  ///
  /// A marker is never fetched over HTTP: it is local identity, not a url.
  Future<String?> resolve(
    String value, {
    Map<int, String>? pendingPaths,
  }) async {
    final v = value.trim();
    if (v.isEmpty) return null;

    // Any `pending:` value resolves from the staging map or not at all.
    // Falling through to the network for a malformed marker would turn a
    // local id into a request path.
    if (v.startsWith(kPendingMarkerPrefix)) {
      final markerId = parsePendingMarkerId(v);
      if (markerId == null) return null;
      return pendingPaths?[markerId];
    }

    try {
      final hit = await cache.findByUrl(v);
      if (hit != null && await File(hit.localPath).exists()) {
        await cache.touch(v);
        return hit.localPath;
      }
      // A row whose file is gone is a MISS, not an error: cache content is
      // non-authoritative and can always be re-fetched.
      if (!isOnline()) return null;

      final bytes = await fetch(v);
      if (bytes == null || bytes.isEmpty) return null;

      final dest = await MediaStore.cachePathFor(v);
      final file = File(dest);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      await cache.upsert(
        fileUrl: v,
        localPath: dest,
        sizeBytes: bytes.length,
        source: MediaSource.downloaded,
      );
      return dest;
    } catch (e, st) {
      sdkLog('MediaResolver.resolve($v) failed — $e\n$st');
      return null;
    }
  }
}
