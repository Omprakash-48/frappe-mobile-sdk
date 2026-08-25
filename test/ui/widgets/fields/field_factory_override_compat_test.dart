// `FieldFactory.createField` is documented as the supported extension point for
// customising field construction, and Dart requires an override to redeclare
// EVERY named parameter of the method it overrides. A new parameter therefore
// breaks every existing host subclass at compile time, and a default value does
// not save it — a caller holding a `FieldFactory` reference may still pass the
// argument explicitly. Host capabilities are carried as instance state for that
// reason; `capDataLength`, `errorTextResolver` and `reclaimAttachment` all say
// so in their own docstrings.
//
// The baseline pinned here is the signature published in **v2.0.0-beta.2** —
// what a host actually compiles against, which is the only baseline that can
// break one. (`develop` is behind that tag and is NOT the reference.) These
// files compiling IS the assertion; there is nothing for an expectation to
// check that the analyzer does not already reject.
//
// This regression exists because five parameters — `isOnline`,
// `pendingAttachmentPaths`, `mediaResolver`, `isOfflineMode`, `imagePickSource`
// — were threaded through `createField` earlier on this branch and did break
// it. The previous version of this file pinned the branch's own signature,
// those five included, so it passed while the break was live. Pin the published
// signature, not the working one.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/image_pick_source.dart';
import 'package:frappe_mobile_sdk/src/models/link_filter_result.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';

/// The `createField` override signature as published in v2.0.0-beta.2,
/// extracted verbatim. It stops compiling the moment the base signature grows.
class PublishedSignatureFactory extends FieldFactory {
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
  }) {
    // Delegating with a subset of the arguments is the documented pattern, so
    // exercise it rather than returning a bare null.
    return super.createField(
      field: field,
      value: value,
      onChanged: onChanged,
      enabled: enabled,
      formData: formData,
      style: style,
    );
  }
}

/// A subclass that DECLARES the five parameters the branch briefly added.
///
/// Removing them from the base is not itself a break: an override may carry
/// named parameters the base does not declare — only *dropping* one the base
/// declares is illegal. This pins that asymmetry, so a host that already
/// adapted to the intermediate signature keeps compiling too.
class WidenedSignatureFactory extends FieldFactory {
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
  test(
    'a createField override with the published signature still compiles',
    () {
      expect(
        PublishedSignatureFactory().createField(
          field: DocField(fieldname: 'x', fieldtype: 'Data'),
        ),
        isA<BaseField>(),
      );
    },
  );

  test('an override may still declare the five withdrawn parameters', () {
    expect(
      WidenedSignatureFactory().createField(
        field: DocField(fieldname: 'x', fieldtype: 'Data'),
      ),
      isNull,
    );
  });

  test('the five host capabilities are settable as instance state', () {
    final f = FieldFactory()
      ..isOnline = (() => true)
      ..pendingAttachmentPaths = {1: '/tmp/a.jpg'}
      ..mediaResolver = ((value, {pendingPaths}) async => null)
      ..isOfflineMode = (() => false)
      ..imagePickSource = (() => ImagePickSource.camera);

    expect(f.isOnline!(), isTrue);
    expect(f.pendingAttachmentPaths, {1: '/tmp/a.jpg'});
    expect(f.mediaResolver, isNotNull);
    expect(f.isOfflineMode!(), isFalse);
    expect(f.imagePickSource!(), ImagePickSource.camera);
  });
}
