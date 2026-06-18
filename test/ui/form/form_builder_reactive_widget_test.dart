import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  testWidgets(
    'reactive mode: typing field A does not rebuild unrelated field B',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
          DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(meta: meta, mode: FormBuilderMode.reactive),
          ),
        ),
      );
      // Reset debug build counters exposed for tests.
      FrappeFormBuilder.debugFieldBuildCounts.clear();
      // 'Data' fields render with key 'data_<name>' (text_ is for Text/Long Text).
      await tester.enterText(find.byKey(const ValueKey('data_a')), 'hello');
      await tester.pumpAndSettle();
      expect(
        FrappeFormBuilder.debugFieldBuildCounts['b'] ?? 0,
        0,
      ); // B never rebuilt
      expect((FrappeFormBuilder.debugFieldBuildCounts['a'] ?? 0) > 0, true);
    },
  );

  testWidgets(
    'reactive mode: programmatic setValue updates the on-screen field',
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
      controller.setValue('a', 'z'); // external (non-user) write
      await tester.pumpAndSettle();
      expect(find.text('z'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets('reactive submit awaits async validators (validateAsync)', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [DocField(fieldname: 'code', fieldtype: 'Data', label: 'Code')],
    );
    final c = FormController(meta: meta);
    c.addAsyncFieldValidator(
      'code',
      (v, _) async => 'dup',
    ); // async-only failure
    void Function()? submit;
    var submitted = false, failed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            mode: FormBuilderMode.reactive,
            controller: c,
            registerSubmit: (fn) => submit = fn,
            onSubmit: (_) => submitted = true,
            onValidationFailed: () => failed = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    submit!();
    await tester.pumpAndSettle();
    expect(failed, true); // async validator failed -> onValidationFailed
    expect(submitted, false);
    c.dispose();
  });
}
