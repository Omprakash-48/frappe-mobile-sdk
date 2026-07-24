import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Sub-directory under the app documents directory where picked attachment
/// files are copied so they survive OS cache reclaim / camera-process kills
/// until the sync pipeline uploads them.
const String kAttachmentStoreDir = 'mform_attachments';

const Uuid _uuid = Uuid();

/// Copies [source] into `<appDocuments>/[kAttachmentStoreDir]/<id><ext>` and
/// returns the durable absolute path. The extension of [source] is preserved.
/// [nameGen] overrides the generated base filename (test seam).
Future<String> copyToAttachmentStore(
  File source, {
  String Function()? nameGen,
}) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, kAttachmentStoreDir));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final ext = p.extension(source.path); // '' when none, else '.jpg'
  final base = nameGen?.call() ?? _uuid.v4();
  final dest = p.join(dir.path, '$base$ext');
  await source.copy(dest);
  return dest;
}

/// Best-effort delete of a durable attachment copy once it has been uploaded.
/// Never throws — a missing file or permission error is ignored.
Future<void> deleteAttachmentCopy(String path) async {
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {
    // best effort
  }
}
