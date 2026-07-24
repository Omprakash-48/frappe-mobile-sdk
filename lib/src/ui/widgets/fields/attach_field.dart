// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../../../utils/attachment_paths.dart';
import '../../../utils/attachment_pick.dart';
import 'base_field.dart';
import 'field_helpers.dart';
// Reuse the shared full-screen zoomable image viewer (showFullScreenImage /
// showFullScreenImageProvider) so image attachments open exactly like
// ImageField previews, with the same auth headers.
import 'image_field.dart';

/// Widget for Attach field type.
/// When [uploadFile] is set, picks upload to server first and store file_url; otherwise stores local path.
/// When a value is present a View/Open action is shown: image attachments open
/// in a full-screen zoomable viewer, other files are downloaded (with auth via
/// [imageHeaders]) to a temp path and opened in the device's default app.
/// For /private/files/ and /files/, uses the Frappe download_file API and
/// [imageHeaders]/[fileUrlBase] for auth (mirrors ImageField).
class AttachField extends BaseField {
  final Future<String?> Function(File file)? uploadFile;

  /// Base URL of the Frappe server, used to resolve relative file paths into
  /// absolute, authenticated download URLs. Optional for backward-compat.
  final String? fileUrlBase;

  /// Auth headers (e.g. from [FrappeClient.requestHeaders]) so private file URLs
  /// can be fetched. Optional for backward-compat.
  final Map<String, String>? imageHeaders;

  /// Synchronous last-known connectivity. When it returns false (offline) the
  /// picked file is kept as a durable local path for save-time queueing instead
  /// of being uploaded inline. Null → treated as online (upload attempted).
  final bool Function()? isOnline;

  /// Map of `pending_attachments.id` → durable local file path, used to resolve
  /// a `pending:<id>` field value (an offline-picked file not yet uploaded)
  /// for the filename label and View/Open action. Display-only.
  final Map<int, String>? pendingAttachmentPaths;

  const AttachField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
    this.isOnline,
    this.pendingAttachmentPaths,
  });

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  /// Only Frappe server file paths or full URLs are treated as server URLs.
  /// Local absolute paths (/storage/..., /data/..., /home/..., etc.) are NOT
  /// server URLs. Mirrors ImageField._isServerUrl.
  bool _isServerUrl(String? path) {
    if (path == null || path.isEmpty) return false;
    final p = path.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return true;
    if (p.startsWith('/files/') || p.startsWith('/private/files/')) return true;
    if (p.startsWith('/api/method/')) return true;
    return false;
  }

  /// Build display URL: full URLs (S3, http(s)) use as-is.
  /// /private/files/ and /files/ use download_file API so auth works; other /
  /// paths get base prepended. Mirrors ImageField._fullImageUrl.
  String? _fullFileUrl(String? path) {
    if (path == null || path.isEmpty) return path;
    final p = path.trim();
    if (p.isEmpty) return path;
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (!p.startsWith('/') ||
        fileUrlBase == null ||
        fileUrlBase!.trim().isEmpty) {
      return p;
    }
    final base = fileUrlBase!.trim();
    final baseNoSlash = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    if (p.startsWith('/private/files/') || p.startsWith('/files/')) {
      return '$baseNoSlash/api/method/frappe.handler.download_file?file_url=${Uri.encodeComponent(p)}';
    }
    return '$baseNoSlash$p';
  }

  /// True when the stored value points at an image (by extension). Query strings
  /// are stripped first so URLs like `.../file.png?token=...` still match.
  bool _isImage(String path) {
    var lower = path.trim().toLowerCase();
    final q = lower.indexOf('?');
    if (q >= 0) lower = lower.substring(0, q);
    return _imageExtensions.any(lower.endsWith);
  }

  @override
  Widget buildField(BuildContext context) {
    String? filePath = value?.toString();

    return FormBuilderField<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('attach_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: filePath,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      builder: (FormFieldState<String> fieldState) {
        // BaseField.build (the enclosing widget) already renders the
        // external label with required-asterisk + translation. The inline
        // Padding(Text(field.label)) that used to live here was a
        // second copy that skipped the asterisk — removed for visual
        // consistency with text/numeric/etc field widgets.
        final current = (fieldState.value ?? filePath)?.trim();
        final hasValue = current != null && current.isNotEmpty;
        // Resolve a `pending:<id>` marker to its durable local file (display
        // only; stored value stays the marker). Server URLs / local paths pass
        // through. Null => an offline pick whose file isn't resolvable yet.
        final displaySource = attachmentDisplaySource(
          current,
          pendingAttachmentPaths,
        );
        final isPendingUnresolved = hasValue &&
            parsePendingMarkerId(current) != null &&
            displaySource == null;
        final isServer = displaySource != null && _isServerUrl(displaySource);
        final isLocalFile = displaySource != null && !isServer;
        final isImage = displaySource != null && _isImage(displaySource);
        final hasViewable = isServer || isLocalFile;
        final label = !hasValue
            ? 'Select file'
            : (displaySource != null
                ? _getFileName(displaySource)
                : (isPendingUnresolved ? 'Pending upload…' : _getFileName(current)));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled && !field.readOnly
                        ? () async {
                            final result = await FilePicker.pickFiles();
                            if (result != null &&
                                result.files.single.path != null) {
                              final picked = File(result.files.single.path!);
                              // Durable-copy-first; upload inline when online,
                              // else keep the local path for save-time queueing.
                              final stored = await resolvePickedAttachment(
                                picked: picked,
                                online: isOnline?.call() ?? true,
                                uploadFile: uploadFile,
                              );
                              if (stored != null && stored.isNotEmpty) {
                                fieldState.didChange(stored);
                                onChanged?.call(stored);
                              }
                            }
                          }
                        : null,
                    icon: const Icon(Icons.attach_file),
                    label: Text(label),
                  ),
                ),
                // View/Open affordance — available even when the field is
                // read-only/disabled so users can always view an attachment
                // (QA #11). Hidden for an unresolved pending pick (nothing to
                // open yet).
                if (hasViewable)
                  _AttachViewButton(
                    // Images open in the shared full-screen viewer; other files
                    // are downloaded then opened externally.
                    url: isServer
                        ? (_fullFileUrl(displaySource) ?? displaySource)
                        : displaySource,
                    isLocal: isLocalFile,
                    isImage: isImage,
                    headers: imageHeaders,
                    fileName: _getFileName(displaySource),
                  ),
              ],
            ),
            if (hasValue)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  isPendingUnresolved
                      ? 'Attached — pending upload'
                      : (displaySource ?? current),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            fieldErrorText(fieldState),
          ],
        );
      },
    );
  }

  String _getFileName(String path) {
    return path.split('/').last;
  }
}

/// View/Open button for an attachment. Kept stateful so it can show a loading
/// spinner while a non-image file is downloaded (with auth) before being opened
/// in the device's default app.
class _AttachViewButton extends StatefulWidget {
  /// Absolute, authenticated URL for server files, or the local device path.
  final String url;

  /// True when [url] is a local file already on the device (no download needed).
  final bool isLocal;

  /// True when the attachment is an image (opens in the full-screen viewer).
  final bool isImage;

  /// Auth headers used to fetch private server files.
  final Map<String, String>? headers;

  /// Display file name used for the downloaded temp file.
  final String fileName;

  const _AttachViewButton({
    required this.url,
    required this.isLocal,
    required this.isImage,
    required this.headers,
    required this.fileName,
  });

  @override
  State<_AttachViewButton> createState() => _AttachViewButtonState();
}

class _AttachViewButtonState extends State<_AttachViewButton> {
  bool _busy = false;

  Future<void> _open() async {
    // Images: reuse the shared full-screen zoomable viewer.
    if (widget.isImage) {
      if (widget.isLocal) {
        showFullScreenImageProvider(context, FileImage(File(widget.url)));
      } else {
        showFullScreenImage(context, widget.url, widget.headers);
      }
      return;
    }

    // Local non-image file — open directly, no download required.
    if (widget.isLocal) {
      final result = await OpenFilex.open(widget.url);
      if (result.type != ResultType.done && mounted) {
        _showError('Could not open file: ${result.message}');
      }
      return;
    }

    // Remote non-image (PDF/doc/etc.): private Frappe files need auth headers an
    // external app/browser won't have, so fetch the bytes ourselves then open
    // the downloaded temp file.
    setState(() => _busy = true);
    try {
      final response = await http.get(
        Uri.parse(widget.url),
        headers: widget.headers,
      );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final safeName = widget.fileName.isEmpty ? 'attachment' : widget.fileName;
      final file = File('${dir.path}/$safeName');
      await file.writeAsBytes(response.bodyBytes);
      final result = await OpenFilex.open(file.path);
      if (result.type != ResultType.done && mounted) {
        _showError('Could not open file: ${result.message}');
      }
    } catch (e) {
      if (mounted) _showError('Could not open file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(12.0),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      icon: Icon(widget.isImage ? Icons.visibility : Icons.open_in_new),
      tooltip: widget.isImage ? 'View' : 'Open',
      onPressed: _open,
    );
  }
}
