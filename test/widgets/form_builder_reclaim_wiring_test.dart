// The reclaim hook is only a fix if it REACHES the fields.
//
// `MediaStore.discardValue` is the default on both attach widgets, so a missed
// forwarding hop is silent: the field still discards, still deletes, and the
// bug survives exactly where the plumbing stops. Child rows matter as much as
// the parent — they take the same pick/discard path through a nested
// `FrappeFormBuilder` built by `childTableFormBuilder`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  DocTypeMeta parentMeta() => DocTypeMeta(
    name: 'Visit',
    fields: <DocField>[
      DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
      DocField(
        fieldname: 'lines',
        fieldtype: 'Table',
        label: 'Lines',
        options: 'VisitLine',
      ),
    ],
  );

  DocTypeMeta childMeta() => DocTypeMeta(
    name: 'VisitLine',
    fields: <DocField>[
      DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Doc'),
    ],
  );

  Future<void> hook(String? value) async {}

  Future<void> pumpForm(WidgetTester tester, FormBuilderMode mode) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: parentMeta(),
            mode: mode,
            getMeta: (_) async => childMeta(),
            reclaimAttachment: hook,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Both modes build their fields through DIFFERENT methods
  // (`_buildFieldWidget` vs `_buildReactiveField`) and construct their own
  // nested `FrappeFormBuilder` for a child row, so each is a separate pair of
  // hops and neither proves the other.
  for (final mode in FormBuilderMode.values) {
    testWidgets('$mode: the hook reaches parent AND child-row attach fields', (
      tester,
    ) async {
      await pumpForm(tester, mode);

      expect(
        tester.widget<ImageField>(find.byType(ImageField)).reclaimAttachment,
        same(hook),
        reason: 'parent field discards through the host, not MediaStore',
      );

      // The child row renders inside the add-row sheet, through the nested
      // FrappeFormBuilder the parent constructs — a second forwarding hop.
      await tester.tap(find.text('Add Row'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        tester.widget<AttachField>(find.byType(AttachField)).reclaimAttachment,
        same(hook),
        reason:
            'a child row deletes staged bytes on the same path as the '
            'parent',
      );
    });
  }

  testWidgets('a host-supplied FieldFactory gets the hook too', (tester) async {
    // `customFieldFactory` is the documented extension point, and the hook is
    // instance state on the factory rather than a `createField` parameter — so
    // a host factory that is never reconfigured would build fields that still
    // delete on sight.
    final hostFactory = FieldFactory();
    expect(
      hostFactory.reclaimAttachment,
      isNot(same(hook)),
      reason: 'starts on the default; the form must assign over it',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: parentMeta(),
            getMeta: (_) async => childMeta(),
            customFieldFactory: hostFactory,
            reclaimAttachment: hook,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(hostFactory.reclaimAttachment, same(hook));
    expect(
      tester.widget<ImageField>(find.byType(ImageField)).reclaimAttachment,
      same(hook),
    );
  });
}
