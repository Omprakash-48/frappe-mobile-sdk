import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// The Frappe std fields are seeded into `FormController._rawValues` purely so
/// `depends_on` can read them, and `docstatus` is now defaulted to 0 when
/// absent. `_buildReactive` feeds `_controller.values` — which carries them —
/// straight into `FormBuilder.initialValue`, and the legacy `_handleSubmit`
/// copies EVERY non-null key out of `state.value` into the save payload. These
/// tests pin that none of that reaches `onSubmit`.
void main() {
  DocTypeMeta meta() => DocTypeMeta(
    name: 'T',
    fields: [
      DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
      DocField(
        fieldname: 'draft_only',
        fieldtype: 'Data',
        label: 'D',
        dependsOn: 'eval:doc.docstatus == 0',
      ),
    ],
  );

  Future<Map<String, dynamic>?> pumpAndSubmit(
    WidgetTester tester, {
    required Map<String, dynamic>? initialData,
    FormController? controller,
  }) async {
    Map<String, dynamic>? submitted;
    void Function()? submit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta(),
            mode: FormBuilderMode.reactive,
            controller: controller,
            initialData: initialData,
            onSubmit: (d) => submitted = d,
            registerSubmit: (s) => submit = s,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(submit, isNotNull, reason: 'registerSubmit must have been called');
    submit!();
    await tester.pumpAndSettle();
    return submitted;
  }

  const stdKeys = [
    'docstatus',
    'name',
    'owner',
    'doctype',
    'idx',
    '__islocal',
    '__unsaved',
  ];

  testWidgets('the defaulted docstatus does not reach onSubmit', (
    tester,
  ) async {
    // No docstatus in initialData: the controller defaults it to 0 so the
    // draft-only field renders. It must not ride along into the payload.
    final submitted = await pumpAndSubmit(
      tester,
      initialData: const {'a': 'A'},
    );
    expect(submitted, isNotNull);
    expect(submitted!['a'], 'A');
    expect(
      submitted.containsKey('draft_only'),
      isTrue,
      reason: 'the draft-only field is visible on a new doc, so it must save',
    );
    for (final k in stdKeys) {
      expect(
        submitted.containsKey(k),
        isFalse,
        reason: '$k leaked into the save payload',
      );
    }
  });

  testWidgets('std fields supplied by the host do not reach onSubmit', (
    tester,
  ) async {
    final submitted = await pumpAndSubmit(
      tester,
      initialData: const {
        'a': 'A',
        'docstatus': 0,
        'name': 'T-0001',
        'owner': 'a@b.c',
        'doctype': 'T',
        'idx': 3,
        '__islocal': 1,
        '__unsaved': 1,
      },
    );
    expect(submitted, isNotNull);
    expect(submitted!['a'], 'A');
    for (final k in stdKeys) {
      expect(
        submitted.containsKey(k),
        isFalse,
        reason: '$k leaked into the save payload',
      );
    }
  });

  testWidgets('a host-supplied controller does not leak them either', (
    tester,
  ) async {
    final submitted = await pumpAndSubmit(
      tester,
      initialData: null,
      controller: FormController(
        meta: meta(),
        initialData: const {'a': 'A', 'docstatus': 0, 'name': 'T-1'},
      ),
    );
    expect(submitted, isNotNull);
    for (final k in stdKeys) {
      expect(
        submitted!.containsKey(k),
        isFalse,
        reason: '$k leaked into the save payload',
      );
    }
  });

  testWidgets('the legacy path is unaffected by the docstatus default', (
    tester,
  ) async {
    // FormController is not involved in legacy mode, so a form with no
    // docstatus must behave exactly as before: the draft-only field is gated
    // false and dropped, and no std key is invented.
    Map<String, dynamic>? submitted;
    void Function()? submit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta(),
            initialData: const {'a': 'A'},
            onSubmit: (d) => submitted = d,
            registerSubmit: (s) => submit = s,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    submit!();
    await tester.pumpAndSettle();
    final payload = submitted;
    expect(payload, isNotNull);
    expect(payload!['a'], 'A');
    expect(
      payload.containsKey('docstatus'),
      isFalse,
      reason: 'the reactive-only default must not appear in legacy mode',
    );
  });
}
