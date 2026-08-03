import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  testWidgets('reactive mode: child Table field renders (not blank)', (
    tester,
  ) async {
    final childMeta = DocTypeMeta(
      name: 'Child',
      fields: [DocField(fieldname: 'item', fieldtype: 'Data', label: 'Item')],
    );
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(
          fieldname: 'rows',
          fieldtype: 'Table',
          options: 'Child',
          label: 'Rows',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: FormBuilderMode.reactive,
            getMeta: (_) async => childMeta,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Table field renders its add control + empty state, not a blank SizedBox.
    expect(find.text('Add Row'), findsOneWidget);
    expect(find.text('No records added'), findsOneWidget);
  });

  testWidgets(
    'reactive mode: an app-passed controller is NOT disposed on unmount',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'T',
        fields: [DocField(fieldname: 'a', fieldtype: 'Data', label: 'A')],
      );
      final controller = FormController(meta: meta);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta,
              mode: FormBuilderMode.reactive,
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Unmount the form.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox())),
      );
      await tester.pumpAndSettle();
      // A disposed ChangeNotifier throws on notifyListeners; surviving = not disposed.
      expect(() => controller.setValue('a', 'x'), returnsNormally);
      expect(controller.getValue('a'), 'x');
      controller.dispose();
    },
  );
}
