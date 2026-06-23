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

  testWidgets(
    'reactive mode: changing a link_filters source rebuilds the dependent Link',
    (tester) async {
      // Regression for the District-stuck-on-"Select state first" bug: a Link
      // field whose options are filtered by another field (link_filters) has
      // no depends_on, so a parent change alters neither its own value nor its
      // FieldUiState. Before the fix its reactive host never rebuilt, so it kept
      // stale parent data and never re-resolved options.
      final meta = DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 'state', fieldtype: 'Data', label: 'State'),
          DocField(
            fieldname: 'district',
            fieldtype: 'Link',
            label: 'District',
            options: 'District',
            linkFilters: '[["District","state","=","eval:doc.state"]]',
          ),
        ],
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
      FrappeFormBuilder.debugFieldBuildCounts.clear();

      // Change the link_filters source. The dependent Link must rebuild so its
      // didUpdateWidget can re-resolve options against the new parent value.
      controller.setValue('state', 'Madhya Pradesh');
      await tester.pumpAndSettle();

      expect(
        (FrappeFormBuilder.debugFieldBuildCounts['district'] ?? 0) > 0,
        true,
        reason:
            'dependent Link did not rebuild when its link_filters source changed',
      );
      controller.dispose();
    },
  );

  testWidgets('reactive mode: an in-progress decimal is not clobbered', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [DocField(fieldname: 'w', fieldtype: 'Float', label: 'W')],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(meta: meta, mode: FormBuilderMode.reactive),
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('numeric_w')), '7.');
    await tester.pumpAndSettle();
    expect(find.text('7.'), findsOneWidget);
  });
}
