import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  testWidgets('controller.goToTab drives the rendered TabController', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
        DocField(fieldtype: 'Tab Break', label: 'Two'),
        DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
      ],
    );
    final c = FormController(meta: meta);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: FormBuilderMode.reactive,
            controller: c,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    c.goToTab(1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('data_b')), findsOneWidget);
    c.dispose();
  });

  testWidgets('reactive section becomes visible when its gate flips', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(fieldname: 'show', fieldtype: 'Check', label: 'Show'),
        DocField(
          fieldtype: 'Section Break',
          label: 'Sec',
          dependsOn: 'eval:doc.show == 1',
        ),
        DocField(fieldname: 'secret', fieldtype: 'Data', label: 'Secret'),
      ],
    );
    final c = FormController(meta: meta);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: FormBuilderMode.reactive,
            controller: c,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('data_secret')), findsNothing);
    c.setValue('show', 1);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('data_secret')), findsOneWidget);
    c.dispose();
  });

  testWidgets('field hidden by own depends_on reports unmounted', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(fieldname: 'g', fieldtype: 'Check', label: 'G'),
        DocField(
          fieldname: 'd',
          fieldtype: 'Data',
          label: 'D',
          dependsOn: 'eval:doc.g == 1',
        ),
      ],
    );
    final c = FormController(meta: meta);
    final kinds = <FieldLifecycleKind>[];
    c.fieldLifecycle
        .where((e) => e.field == 'd')
        .listen((e) => kinds.add(e.kind));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: FormBuilderMode.reactive,
            controller: c,
          ),
        ),
      ),
    );
    c.setValue('g', 1); // d shown
    await tester.pumpAndSettle();
    c.setValue('g', 0); // d hidden -> host stays, renders SizedBox -> unmounted
    await tester.pumpAndSettle();
    expect(kinds.contains(FieldLifecycleKind.mounted), true);
    expect(kinds.contains(FieldLifecycleKind.unmounted), true);
    c.dispose();
  });

  testWidgets(
    'app-owned controller survives view unmount (no throw on later use)',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
          DocField(fieldtype: 'Tab Break', label: 'Two'),
          DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
        ],
      );
      final c = FormController(meta: meta);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta,
              mode: FormBuilderMode.reactive,
              controller: c,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pumpAndSettle();
      expect(() {
        c.goToTab(1);
        c.requestScrollToField('a');
      }, returnsNormally);
      c.dispose();
    },
  );
}
