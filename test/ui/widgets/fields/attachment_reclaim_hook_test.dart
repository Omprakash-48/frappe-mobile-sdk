// The discard button must not delete staged bytes on its own authority.
//
// `MediaStore.discardValue` deletes any path inside `outbox/`, reasoning that a
// column holding a raw staged path was never saved. The FIELD's value does not
// obey that rule: `LocalWriter` rewrites the column to `pending:<id>` inside the
// save transaction while the open form keeps the raw path, so a discard after a
// save was destroying bytes a committed `pending_attachments` row still owned.
//
// The fix routes both reclaim sites through an injected hook the host wires to
// `OfflineRepository.reclaimDiscardedAttachment`, which refuses a referenced
// file. These tests pin the routing; the refusal itself is covered by
// `offline_repository_attachment_reclaim_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';

const String _staged = '/app/mform_attachments/outbox/uid-1/photo.jpg';

Future<void> _pump(WidgetTester tester, Widget field) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: FormBuilder(child: field)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ImageField discard reclaims through the injected hook', (
    tester,
  ) async {
    final reclaimed = <String?>[];
    await _pump(
      tester,
      ImageField(
        field: DocField(
          fieldname: 'pic',
          fieldtype: 'Attach Image',
          label: 'Photo',
        ),
        value: _staged,
        reclaimAttachment: (v) async => reclaimed.add(v),
      ),
    );

    await tester.tap(find.byTooltip('Remove photo'));
    await tester.pumpAndSettle();

    expect(reclaimed, [_staged]);
  });

  testWidgets('AttachField discard reclaims through the injected hook', (
    tester,
  ) async {
    final reclaimed = <String?>[];
    await _pump(
      tester,
      AttachField(
        field: DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Doc'),
        value: _staged,
        reclaimAttachment: (v) async => reclaimed.add(v),
      ),
    );

    await tester.tap(find.byTooltip('Remove attachment'));
    await tester.pumpAndSettle();

    expect(reclaimed, [_staged]);
  });
}
