import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// Guard tests for `parent` threading — **all skipped, all currently failing.**
///
/// `FrappeFormBuilder.parentFormData` and `FormController.parentData` ship in
/// this release, so the entry point is public before the implementation behind
/// it is correct. These pin what the behaviour must become, so the surface does
/// not sit unattended: remove the `skip:` when the parent-threading follow-up
/// lands and they should pass unchanged.
///
/// Each was reproduced against this branch — they are known-failing, not
/// speculative. The reproduction is recorded in the comment on each test.
void main() {
  DocTypeMeta meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

  // H1 — `effectiveParentFormData` (form_builder.dart:448) is non-nullable
  // (`widget.parentFormData ?? _formData`), so DependsOnEvaluator's
  // `parentData == null ? doc : …` alias branch is unreachable from the widget.
  // In reactive mode `_evalData` returns the live `_controller.values` while
  // `parent` gets `_formData`, which only `_onFieldValueChanged` writes — wired
  // at :1393, the legacy path only. So `parent` is frozen at mount.
  //
  // Reproduced: the section stays hidden 0 -> 0 after the trigger flips, while
  // the same section gated on `doc.trigger` goes 0 -> 1.
  testWidgets(
    'H1: with no parentFormData, parent follows the live doc',
    (tester) async {
      final m = meta([
        DocField(fieldname: 'trigger', fieldtype: 'Data', label: 'Trigger'),
        DocField(
          fieldname: 'sec',
          fieldtype: 'Section Break',
          label: 'Sec',
          dependsOn: 'eval:parent.trigger == "GO"',
        ),
        DocField(fieldname: 'under', fieldtype: 'Data', label: 'Under'),
      ]);
      final c = FormController(meta: m, initialData: const {'trigger': 'NO'});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: m,
              mode: FormBuilderMode.reactive,
              controller: c,
              initialData: const {'trigger': 'NO'},
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('data_under')), findsNothing);
      c.setValue('trigger', 'GO');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('data_under')),
        findsOneWidget,
        reason: 'Desk aliases parent to doc when there is no parent form',
      );
    },
    // KNOWN FAILING: parent is a mount-time snapshot.
    skip: true,
  );

  // H2 — `didUpdateWidget` touches `parentFormData` only to pass
  // `effectiveParentFormData` DOWN to a child builder (:1754). It never
  // re-assigns `_controller.parentData`, which is written once in initState
  // (:541-543), so a host handing over a fresh parent map on rebuild keeps
  // being evaluated against the mount-time one.
  testWidgets(
    'H2: a new parentFormData on rebuild is re-threaded',
    (tester) async {
      final m = meta([
        DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Qty'),
        DocField(
          fieldname: 'gated',
          fieldtype: 'Data',
          label: 'Gated',
          dependsOn: "eval:parent.kind == 'X'",
        ),
      ]);
      Widget build(Map<String, dynamic> parent) => MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: m,
            mode: FormBuilderMode.reactive,
            parentFormData: parent,
          ),
        ),
      );
      await tester.pumpWidget(build(const {'kind': 'Y'}));
      expect(find.byKey(const ValueKey('data_gated')), findsNothing);
      await tester.pumpWidget(build(const {'kind': 'X'}));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('data_gated')),
        findsOneWidget,
        reason: 'the rebuild supplied a parent whose kind now matches',
      );
    },
    // KNOWN FAILING: parentFormData is assigned once, in initState.
    skip: true,
  );

  // H3 — the `parentData` setter calls `notifyListeners()`, and
  // form_builder.dart:542 invokes it from initState. That branch exists only
  // for a HOST-supplied controller, which may already carry host listeners; a
  // host listener that calls setState then does so during the child's mount.
  //
  // Reproduced: throws `setState() or markNeedsBuild() called during build.`
  testWidgets(
    'H3: wiring parentData into a host controller does not notify during mount',
    (tester) async {
      final controller = FormController(
        meta: meta([DocField(fieldname: 'a', fieldtype: 'Data', label: 'A')]),
      );
      await tester.pumpWidget(MaterialApp(home: _Host(controller: controller)));
      expect(
        tester.takeException(),
        isNull,
        reason: 'a host listener must not be notified mid-mount',
      );
    },
    // KNOWN FAILING: the setter notifies from initState.
    skip: true,
  );
}

/// A host that owns the controller and rebuilds when it changes — the ordinary
/// reason to hold one yourself (enabling a Save button).
class _Host extends StatefulWidget {
  const _Host({required this.controller});
  final FormController controller;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int _n = 0;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(() {
      if (mounted) setState(() => _n++);
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('n=$_n'),
        Expanded(
          child: FrappeFormBuilder(
            meta: DocTypeMeta(
              name: 'T',
              fields: [DocField(fieldname: 'a', fieldtype: 'Data', label: 'A')],
            ),
            mode: FormBuilderMode.reactive,
            controller: widget.controller,
            parentFormData: const {'kind': 'X'},
          ),
        ),
      ],
    ),
  );
}
