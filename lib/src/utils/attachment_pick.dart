import 'dart:io';

import 'package:flutter/foundation.dart';

import 'attachment_storage.dart';

/// Uploads a picked file to the Frappe server, returning the stored file
/// reference (`file_url`) or null on failure. Matches the closure the SDK's
/// `FormScreen` wires from `api.attachment.uploadFile`.
typedef AttachmentUploadFn = Future<String?> Function(File file);

/// Resolves a just-picked attachment file into the value a field should store.
///
/// Always copies the picked file into the durable attachment store FIRST — the
/// picker/camera hands back a volatile cache path the OS can reclaim (and the
/// host process can be killed mid-capture), so the durable copy is the safety
/// net for both online and offline.
///
/// - **Online** with an [uploadFile]: upload from the durable copy; on success
///   return the server `file_url` and delete the now-redundant copy.
/// - **Offline**, no uploader, or a failed/empty upload: return the durable
///   local path so the save-time producer can queue it for later upload.
///
/// [copyToStore] / [deleteCopy] are injectable for testing.
Future<String?> resolvePickedAttachment({
  required File picked,
  required bool online,
  AttachmentUploadFn? uploadFile,
  Future<String> Function(File source) copyToStore = copyToAttachmentStore,
  Future<void> Function(String path) deleteCopy = deleteAttachmentCopy,
}) async {
  final durablePath = await copyToStore(picked);
  if (uploadFile != null && online) {
    try {
      final url = await uploadFile(File(durablePath));
      if (url != null && url.isNotEmpty) {
        await deleteCopy(durablePath);
        return url;
      }
    } catch (e, st) {
      debugPrint('resolvePickedAttachment: upload failed, keeping local — $e\n$st');
    }
  }
  return durablePath;
}
