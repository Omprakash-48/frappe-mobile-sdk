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
    FormBuilderMode mode = FormBuilderMode.reactive,
  }) async {
    Map<String, dynamic>? submitted;
    void Function()? submit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta(),
            mode: mode,
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

  // ── an explicit null docstatus, in BOTH engines ──────────────────────────
  //
  // `FormBuilderMode.legacy` is the CONSTRUCTOR DEFAULT, and it never goes
  // through `FormController._seedDefaults`: `initState` does a bare
  // `_formData.addAll(widget.initialData ?? {})`, so `{'docstatus': null}`
  // lands in the scope verbatim. Defaulting only on key ABSENCE therefore left
  // the default engine on the original failure mode — field hidden, and
  // dropped from the payload by the same `depends_on` sweep.
  //
  // The default is applied at the evaluator's choke point now, so it holds for
  // every caller and every scope rather than for one engine's seeding.
  group('an explicit null docstatus behaves like an absent one', () {
    for (final mode in FormBuilderMode.values) {
      testWidgets('$mode: the draft-only field is visible and saved', (
        tester,
      ) async {
        final submitted = await pumpAndSubmit(
          tester,
          mode: mode,
          initialData: const {'a': 'A', 'docstatus': null},
        );
        expect(submitted, isNotNull);
        expect(
          submitted!.containsKey('draft_only'),
          isTrue,
          reason:
              'null docstatus must read as draft (0), so the field survives',
        );
        for (final k in stdKeys) {
          expect(
            submitted.containsKey(k),
            isFalse,
            reason: '$k leaked into the save payload',
          );
        }
      });

      testWidgets('$mode: a submitted doc still hides the draft-only field', (
        tester,
      ) async {
        // The correct-negative: the fix must not blanket-show the field.
        final submitted = await pumpAndSubmit(
          tester,
          mode: mode,
          initialData: const {'a': 'A', 'docstatus': 1},
        );
        expect(submitted, isNotNull);
        expect(submitted!.containsKey('draft_only'), isFalse);
      });
    }
  });

  // ── `__islocal` is derived in BOTH engines ───────────────────────────────
  //
  // Same defect as the docstatus one above, one field over: the derivation
  // lived only in `FormController._seedDefaults`, and `FormBuilderMode.legacy`
  // — the constructor default — never constructs a FormController. There,
  // `doc.__islocal` read undefined, so `!doc.__islocal` was TRUE on a brand-new
  // document and the SDK behaved as though every document were already saved:
  // it showed the saved-only fields Desk hides on create, and for
  // `read_only_depends_on` it LOCKED a field the user is there to fill in.
  //
  // Derived at the evaluator choke point now, from the absence of a `name` —
  // Frappe's own new-doc test (`document.py:539`: `__islocal or not name`).
  group('__islocal is derived from the absence of a name in both engines', () {
    DocTypeMeta savedOnlyMeta() => DocTypeMeta(
      name: 'T',
      fields: [
        DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
        DocField(
          fieldname: 'saved_only',
          fieldtype: 'Data',
          label: 'S',
          dependsOn: 'eval:!doc.__islocal',
        ),
      ],
    );

    Future<Map<String, dynamic>?> submitWith(
      WidgetTester tester,
      FormBuilderMode mode,
      Map<String, dynamic> initialData,
    ) async {
      Map<String, dynamic>? submitted;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: savedOnlyMeta(),
              mode: mode,
              initialData: initialData,
              onSubmit: (d) => submitted = d,
              registerSubmit: (s) => submit = s,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      return submitted;
    }

    for (final mode in FormBuilderMode.values) {
      testWidgets('$mode: a NEW doc (no name) hides the saved-only field', (
        tester,
      ) async {
        final submitted = await submitWith(tester, mode, const {'a': 'A'});
        expect(submitted, isNotNull);
        expect(
          submitted!.containsKey('saved_only'),
          isFalse,
          reason: 'no name means __islocal, so Desk hides this on create',
        );
        expect(submitted.containsKey('__islocal'), isFalse);
      });

      testWidgets('$mode: a SAVED doc (has name) shows the saved-only field', (
        tester,
      ) async {
        // The correct-negative: the derivation must not hide the field forever.
        final submitted = await submitWith(tester, mode, const {
          'a': 'A',
          'name': 'T-0001',
        });
        expect(submitted, isNotNull);
        expect(submitted!.containsKey('saved_only'), isTrue);
        expect(submitted.containsKey('__islocal'), isFalse);
      });

      testWidgets('$mode: an explicit __islocal from the host still wins', (
        tester,
      ) async {
        // A host that says "saved" while supplying no name is believed.
        final submitted = await submitWith(tester, mode, const {
          'a': 'A',
          '__islocal': 0,
        });
        expect(submitted, isNotNull);
        expect(submitted!.containsKey('saved_only'), isTrue);
      });
    }
  });
}
