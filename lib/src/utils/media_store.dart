import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'sdk_log.dart';

/// Root sub-directory under the app documents directory.
const String kAttachmentStoreDir = 'mform_attachments';

/// Staging for picked files that have not been uploaded yet. Owned by
/// `pending_attachments`. NEVER evictable — these are the only copy of the
/// bytes in existence.
const String kOutboxSubDir = 'outbox';

/// Content store keyed by the server `file_url`. Evictable (Phase 2) and wiped
/// on logout. Always re-fetchable, so losing it is never a correctness problem.
const String kCacheSubDir = 'cache';

const Uuid _uuid = Uuid();

/// Two-directory media store backing the attachment pipeline.
///
/// There is NO transaction spanning the filesystem and SQLite, and this class
/// does not pretend otherwise. Callers order their writes so that every
/// divergence is self-healing: a cache file with no `media_cache` row is
/// harmless orphan bytes, and a row with no file is a cache miss.
class MediaStore {
  static String? _testRoot;

  /// Test seam. `getApplicationDocumentsDirectory()` needs a platform channel
  /// that plain `flutter test` does not provide, and mocking path_provider per
  /// test file is more machinery than one explicit override.
  @visibleForTesting
  static void overrideRootForTest(String? absoluteRoot) {
    _testRoot = absoluteRoot;
  }

  static Future<String> _root() async {
    final base = _testRoot ?? (await getApplicationDocumentsDirectory()).path;
    return p.join(base, kAttachmentStoreDir);
  }

  /// Copies [source] into `outbox/<id>/<original filename>` and returns the
  /// durable path.
  ///
  /// The file keeps the name the USER picked; uniqueness comes from the
  /// generated parent directory. That matters because the original filename
  /// cannot travel any other way — it does not fit through the field's
  /// `onChanged`, and renaming to `<uuid><ext>` (the previous behaviour) lost
  /// it permanently, so every upload landed server-side as an opaque uuid.
  static Future<String> stageToOutbox(
    File source, {
    String Function()? nameGen,
  }) async {
    final base = nameGen?.call() ?? _uuid.v4();
    final dir = Directory(p.join(await _root(), kOutboxSubDir, base));
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(dir.path, p.basename(source.path));
    await source.copy(dest);
    return dest;
  }

  /// Deterministic cache location for [fileUrl].
  ///
  /// Hashing the url keeps the name filesystem-safe and collision-free while
  /// staying reproducible, so a lookup can find the path without consulting
  /// the index. [sourcePath] supplies the extension when the url has none
  /// (e.g. a `download_file` proxy url that carries the name in its query).
  /// PURE: computes a path and creates nothing. Asking where a file would live
  /// must not resurrect a store that was just wiped — writers call
  /// [_ensureParent] themselves.
  static Future<String> cachePathFor(
    String fileUrl, {
    String? sourcePath,
  }) async {
    final dirPath = p.join(await _root(), kCacheSubDir);
    final digest = sha256.convert(utf8.encode(fileUrl)).toString();
    var ext = p.extension(fileUrl);
    if (ext.isEmpty && sourcePath != null) ext = p.extension(sourcePath);
    return p.join(dirPath, '$digest$ext');
  }

  /// Creates the parent directory of [filePath] if needed.
  static Future<void> _ensureParent(String filePath) async {
    final parent = Directory(p.dirname(filePath));
    if (!await parent.exists()) await parent.create(recursive: true);
  }

  /// Moves a staged file into the cache under [fileUrl]'s key.
  ///
  /// IDEMPOTENT: when the destination already exists this reports success even
  /// if the staged file is gone, so an interrupted upload resumes without
  /// re-uploading. Returns false only when neither source nor destination
  /// exists — cache population must never silently claim success.
  static Future<bool> moveToCache(String stagedPath, String fileUrl) async {
    final dest = await cachePathFor(fileUrl, sourcePath: stagedPath);
    final destFile = File(dest);
    if (await destFile.exists()) {
      // Already moved by a previous attempt; clean up any staged leftover.
      await deleteOutboxCopy(stagedPath);
      return true;
    }
    final src = File(stagedPath);
    if (!await src.exists()) return false;
    await _ensureParent(dest);
    try {
      await src.rename(dest);
      return true;
    } catch (e, st) {
      // `rename` fails across filesystems (Android app-private vs external).
      sdkLog(
        'MediaStore.moveToCache: rename failed, falling back to copy — $e\n$st',
      );
      try {
        await src.copy(dest);
        await deleteOutboxCopy(stagedPath);
        return true;
      } catch (e2, st2) {
        sdkLog('MediaStore.moveToCache: copy fallback failed — $e2\n$st2');
        return false;
      }
    }
  }

  /// Best-effort delete of a staged copy. Never throws.
  ///
  /// Also prunes the per-pick parent directory, which would otherwise
  /// accumulate one empty folder per attachment forever.
  static Future<void> deleteOutboxCopy(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
      final parent = f.parent;
      // Only ever prune a directory that sits directly under outbox/, so a
      // caller passing an arbitrary path can never delete something else.
      final outbox = p.join(await _root(), kOutboxSubDir);
      if (p.dirname(parent.path) == outbox && await parent.exists()) {
        final remaining = await parent.list().isEmpty;
        if (remaining) await parent.delete();
      }
    } catch (e, st) {
      sdkLog('MediaStore.deleteOutboxCopy($path) failed — $e\n$st');
    }
  }

  /// Total bytes across both directories. Drives the host-facing
  /// "clear cached media" affordance while eviction is still unbuilt.
  static Future<int> storeSizeBytes() async {
    var total = 0;
    for (final sub in const [kOutboxSubDir, kCacheSubDir]) {
      final dir = Directory(p.join(await _root(), sub));
      if (!await dir.exists()) continue;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (err, st) {
            sdkLog(
              'MediaStore.storeSizeBytes: stat(${e.path}) failed — $err\n$st',
            );
          }
        }
      }
    }
    return total;
  }

  /// Removes BOTH directories. Used by logout and wipe: cached media must not
  /// outlive the data it belongs to on a shared device.
  ///
  /// This also clears `outbox/`, which holds the only copy of any un-uploaded
  /// attachment — callers must treat it as destructive.
  static Future<void> clearAll() async {
    final dir = Directory(await _root());
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e, st) {
      sdkLog('MediaStore.clearAll failed — $e\n$st');
    }
  }
}
