// Pins the bug → fix → contract for the hidden-section auto-clear.
//
// Before the fix, fields inside a section whose `depends_on` evaluates false
// never had `_buildFieldWidget` called, so their stale values persisted in
// `_formData` and shipped on save. This test enters a value into a
// section-gated field, flips the section's gate, and asserts the value is
// gone from the emitted formData.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'TestForm',
  fields: [
    DocField(fieldname: 'purpose', fieldtype: 'Data', label: 'Purpose'),
    // Section gated on purpose == 'A'. When purpose flips to 'B', the
    // section hides AND its child fields must clear.
    DocField(
      fieldname: 'sec_a',
      fieldtype: 'Section Break',
      label: 'A Section',
      dependsOn: "eval:doc.purpose == 'A'",
    ),
    DocField(fieldname: 'a_field', fieldtype: 'Data', label: 'A Field'),
    // Field with its OWN depends_on outside any hidden section — already
    // covered by the existing build-time clear, kept here as a control.
    DocField(
      fieldname: 'top_level',
      fieldtype: 'Data',
      label: 'Top Level',
      dependsOn: "eval:doc.purpose == 'A'",
    ),
  ],
);

void main() {
  testWidgets(
    'fields inside a section that hides are removed from formData on save',
    (tester) async {
      Map<String, dynamic>? submitted;
      void Function()? doSubmit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: _meta(),
              initialData: const {
                'purpose': 'A',
                'a_field': 'stale-value',
                'top_level': 'top-stale',
              },
              onSubmit: (d) => submitted = d,
              registerSubmit: (fn) => doSubmit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sanity: both fields populated and visible at start.
      expect(find.text('stale-value'), findsOneWidget);
      expect(find.text('top-stale'), findsOneWidget);

      // Flip the gate: purpose A -> B.
      await tester.enterText(find.byKey(const ValueKey('data_purpose')), 'B');
      await tester.pumpAndSettle();

      // Trigger the save and read what the form passes to onSubmit.
      expect(doSubmit, isNotNull, reason: 'registerSubmit must wire');
      doSubmit!();
      await tester.pumpAndSettle();

      expect(submitted, isNotNull);
      expect(
        submitted!.containsKey('top_level'),
        isFalse,
        reason:
            'Top-level field with depends_on flipping false must be cleared from save payload.',
      );
      expect(
        submitted!.containsKey('a_field'),
        isFalse,
        reason:
            'Field inside a hidden section must also be cleared from save payload. THIS is the bug fix.',
      );
    },
  );
}
