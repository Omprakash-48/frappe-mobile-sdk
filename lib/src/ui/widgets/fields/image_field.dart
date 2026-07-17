// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:image_picker/image_picker.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Shows [image] full-screen in a zoomable, dismissible viewer with a dark
/// scrim and a close (X) button. Pinch-zoom / pan via [InteractiveViewer];
/// never crops (BoxFit.contain). Shared by ImageField (thumbnail tap) and
/// AttachField (image attachments).
void showFullScreenImageProvider(BuildContext context, ImageProvider image) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (dialogContext) {
      return Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4.0,
                child: Image(
                  image: image,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(
                        Icons.broken_image,
                        color: Colors.white70,
                        size: 64,
                      ),
                    );
                  },
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Shows a network image full-screen with optional auth [headers]. Shared entry
/// point used by ImageField and AttachField so private Frappe files load with
/// the same auth as inline previews.
void showFullScreenImage(
  BuildContext context,
  String url,
  Map<String, String>? headers,
) {
  showFullScreenImageProvider(context, NetworkImage(url, headers: headers));
}

/// Widget for Image/Attach Image field type.
/// When [uploadFile] is set, picks upload to server first and store file_url; otherwise stores local path.
/// For /private/files/ and /files/, uses Frappe download_file API and [imageHeaders] for auth.
class ImageField extends BaseField {
  final Future<String?> Function(File file)? uploadFile;
  final String? fileUrlBase;

  /// Auth headers (e.g. from [FrappeClient.requestHeaders]) so private file URLs load.
  final Map<String, String>? imageHeaders;

  const ImageField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
  });

  /// Only Frappe server file paths or full URLs are treated as server URLs.
  /// Local absolute paths (/storage/..., /data/..., /home/..., etc.) are NOT server URLs.
  bool _isServerUrl(String? path) {
    if (path == null || path.isEmpty) return false;
    final p = path.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return true;
    if (p.startsWith('/files/') || p.startsWith('/private/files/')) return true;
    // multi_cloud_storage (and any Frappe method-served file) returns a
    // RELATIVE proxy URL, e.g.
    //   /api/method/multi_cloud_storage.controller.generate_file?key=...
    // Without this, such values fail the check below, get mistaken for a local
    // path, and render via Image.file (broken). Treat method endpoints as
    // server URLs so _fullImageUrl prepends the base and the preview loads via
    // Image.network(base + path) with auth headers. (Cloud-backed private files.)
    if (p.startsWith('/api/method/')) return true;
    return false;
  }

  /// True if url is absolute (http/https), so Image.network can use it.
  bool _isFullUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.trim();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /// Build display URL: full URLs (S3, http(s)) use as-is.
  /// /private/files/ and /files/ use download_file API so auth works; other / paths get base prepended.
  String? _fullImageUrl(String? path) {
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

  Future<void> _onImagePicked(
    FormFieldState<String> fieldState,
    File file,
  ) async {
    if (uploadFile != null) {
      try {
        final url = await uploadFile!(file);
        if (url != null && url.isNotEmpty) {
          fieldState.didChange(url);
          onChanged?.call(url);
        }
        // On upload failure or empty response, do not store local path (server expects file_url)
      } catch (e, st) {
        // Do not fall back to local path; leave field unchanged so wrong URL is never sent
        debugPrint('ImageField: uploadFile failed — $e\n$st');
      }
    } else {
      fieldState.didChange(file.path);
      onChanged?.call(file.path);
    }
  }

  @override
  Widget buildField(BuildContext context) {
    final raw = value?.toString();
    final String? imagePath = raw?.trim();

    return FormBuilderField<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('image_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: imagePath,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      builder: (FormFieldState<String> fieldState) {
        final raw = fieldState.value ?? imagePath;
        final currentValue = raw?.toString().trim();
        final isUrl = _isServerUrl(currentValue);
        final displayUrl = isUrl ? _fullImageUrl(currentValue) : null;

        // BaseField.build (the enclosing widget) already renders the
        // external label with required-asterisk; the inline label that
        // used to live here is gone for parity with text/numeric/etc.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (currentValue != null && currentValue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: GestureDetector(
                  // Viewing is always allowed — even when the field is
                  // read-only/disabled the user can still open the full-screen
                  // viewer (QA #11).
                  onTap: () {
                    if (_isFullUrl(displayUrl)) {
                      showFullScreenImage(context, displayUrl!, imageHeaders);
                    } else if (!isUrl) {
                      showFullScreenImageProvider(
                        context,
                        FileImage(File(currentValue)),
                      );
                    }
                  },
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _isFullUrl(displayUrl)
                            ? Image.network(
                                displayUrl!,
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                headers: imageHeaders,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    height: 150,
                                    color: Colors.grey[300],
                                    child: const Icon(Icons.broken_image),
                                  );
                                },
                              )
                            : !isUrl
                            ? Image.file(
                                File(currentValue),
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    height: 150,
                                    color: Colors.grey[300],
                                    child: const Icon(Icons.broken_image),
                                  );
                                },
                              )
                            : Container(
                                height: 150,
                                color: Colors.grey[300],
                                child: const Center(
                                  child: Icon(Icons.broken_image, size: 48),
                                ),
                              ),
                      ),
                      // 'Tap to view' affordance — only shown when the image is
                      // actually viewable full-screen.
                      if (_isFullUrl(displayUrl) || !isUrl)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.fullscreen,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: enabled && !field.readOnly
                      ? () async {
                          final picker = ImagePicker();
                          final result = await picker.pickImage(
                            source: ImageSource.gallery,
                          );
                          if (result != null) {
                            await _onImagePicked(fieldState, File(result.path));
                          }
                        }
                      : null,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: enabled && !field.readOnly
                      ? () async {
                          final picker = ImagePicker();
                          final result = await picker.pickImage(
                            source: ImageSource.camera,
                          );
                          if (result != null) {
                            await _onImagePicked(fieldState, File(result.path));
                          }
                        }
                      : null,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ],
            ),
            fieldErrorText(fieldState),
          ],
        );
      },
    );
  }
}
