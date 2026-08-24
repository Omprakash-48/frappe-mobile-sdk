// A `FieldFactory` subclass whose `createField` override is the signature at
// ca69c95 — this PR's head immediately before the reclaim work — extracted
// verbatim. Dart requires an override to redeclare EVERY named parameter of the
// method it overrides, so a new parameter breaks every existing subclass at
// compile time; `capDataLength` and `errorTextResolver` say so in their own
// docstrings and carry themselves as instance state for exactly that reason.
// This file compiling IS the assertion that the reclaim hook did the same.
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/link_filter_result.dart';
import 'package:frappe_mobile_sdk/src/models/image_pick_source.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';

class PriorSignatureFactory extends FieldFactory {
  @override
  BaseField? createField({
    required DocField field,
    dynamic value,
    ValueChanged<dynamic>? onChanged,
    bool enabled = true,
    List<String>? linkOptions,
    Map<String, dynamic>? formData,
    FieldStyle? style,
    Future<String?> Function(File file)? uploadFile,
    String? fileUrlBase,
    Map<String, String>? imageHeaders,
    Future<DocTypeMeta> Function(String doctype)? getMeta,
    ChildTableFormBuilder? childTableFormBuilder,
    Future<void> Function(DocField field, Map<String, dynamic> formData)?
    onButtonPressed,
    Map<String, dynamic>? parentFormData,
    LinkFilterBuilder? Function(String doctype, String fieldname)?
    getLinkFilterBuilder,
    ValueChanged<bool>? onIsLocalChanged,
    bool Function()? isOnline,
    Map<int, String>? pendingAttachmentPaths,
    ResolveMediaFn? mediaResolver,
    bool Function()? isOfflineMode,
    ImagePickSource Function()? imagePickSource,
  }) {
    return null;
  }
}

void main() {
  test('an existing createField override still compiles', () {
    expect(
      PriorSignatureFactory().createField(
        field: DocField(fieldname: 'x', fieldtype: 'Data'),
      ),
      isNull,
    );
  });
}
