import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

/// Legacy-mode submit must enforce the doctype's mandatory contract over the
/// COMPLETE payload, not just the widgets that happen to be mounted.
/// TabBarView builds tab pages lazily, so `state.saveAndValidate()` never sees
/// reqd fields on other tabs — without a meta-driven sweep those docs save
/// locally and bounce back as a server 417 at sync time.
void main() {
  DocTypeMeta twoTabMeta({bool nameRequired = true}) => DocTypeMeta(
    name: 'Test',
    label: 'Test',
    isTable: false,
    titleField: null,
    searchFields: null,
    fields: [
      DocField(
        fieldname: 'tab_basic',
        fieldtype: 'Tab Break',
        idx: 1,
        label: 'Basic',
      ),
      DocField(
        fieldname: 'phone',
        fieldtype: 'Data',
        idx: 2,
        label: 'Phone',
        reqd: false,
      ),
      DocField(
        fieldname: 'tab_details',
        fieldtype: 'Tab Break',
        idx: 3,
        label: 'Details',
      ),
      DocField(
        fieldname: 'full_name',
        fieldtype: 'Data',
        idx: 4,
        label: 'Full Name',
        reqd: nameRequired,
      ),
    ],
  );

  Future<({void Function() submit, List<Map<String, dynamic>> submitted, List<int> failed})>
  pumpForm(
    WidgetTester tester,
    DocTypeMeta meta, {
    Map<String, dynamic> initialData = const {},
  }) async {
    void Function()? captured;
    final submitted = <Map<String, dynamic>>[];
    final failed = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: initialData,
            onSubmit: submitted.add,
            onValidationFailed: () => failed.add(1),
            registerSubmit: (cb) => captured = cb,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (submit: captured!, submitted: submitted, failed: failed);
  }

  testWidgets('blocks submit when a reqd field on an UNMOUNTED tab is empty', (
    tester,
  ) async {
    final form = await pumpForm(tester, twoTabMeta());

    form.submit(); // user is on tab 1; full_name lives on tab 2
    await tester.pumpAndSettle();
    // flush the delayed inline-error invalidation timer
    await tester.pump(const Duration(milliseconds: 200));

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
  });

  testWidgets('switches to the tab containing the first missing field', (
    tester,
  ) async {
    final form = await pumpForm(tester, twoTabMeta());

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.controller!.index, 1);
  });

  testWidgets('submits when the reqd field on the other tab has a value', (
    tester,
  ) async {
    final form = await pumpForm(
      tester,
      twoTabMeta(),
      initialData: const {'full_name': 'Asha'},
    );

    form.submit();
    await tester.pumpAndSettle();

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
    expect(form.submitted.single['full_name'], 'Asha');
  });

  testWidgets('blocks submit when a reqd Table field has no rows', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'sectors',
          fieldtype: 'Table',
          idx: 1,
          label: 'Sectors',
          reqd: true,
          options: 'Sector Row',
        ),
      ],
    );
    final form = await pumpForm(tester, meta);

    form.submit();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));

    expect(form.submitted, isEmpty);
    expect(form.failed, hasLength(1));
  });

  testWidgets(
    'blocks submit when mandatory_depends_on is satisfied and field is empty',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'Test',
        label: 'Test',
        isTable: false,
        titleField: null,
        searchFields: null,
        fields: [
          DocField(
            fieldname: 'tab_basic',
            fieldtype: 'Tab Break',
            idx: 1,
            label: 'Basic',
          ),
          DocField(
            fieldname: 'want_training',
            fieldtype: 'Check',
            idx: 2,
            label: 'Want Training',
          ),
          DocField(
            fieldname: 'tab_details',
            fieldtype: 'Tab Break',
            idx: 3,
            label: 'Details',
          ),
          DocField(
            fieldname: 'training_topic',
            fieldtype: 'Data',
            idx: 4,
            label: 'Training Topic',
            mandatoryDependsOn: 'eval:doc.want_training==1',
          ),
        ],
      );
      final form = await pumpForm(
        tester,
        meta,
        initialData: const {'want_training': 1},
      );

      form.submit();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));

      expect(form.submitted, isEmpty);
      expect(form.failed, hasLength(1));
    },
  );

  testWidgets('reqd field hidden by depends_on does NOT block submit', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'tab_basic',
          fieldtype: 'Tab Break',
          idx: 1,
          label: 'Basic',
        ),
        DocField(fieldname: 'is_msme', fieldtype: 'Check', idx: 2, label: 'MSME'),
        DocField(
          fieldname: 'tab_details',
          fieldtype: 'Tab Break',
          idx: 3,
          label: 'Details',
        ),
        DocField(
          fieldname: 'udyam_number',
          fieldtype: 'Data',
          idx: 4,
          label: 'Udyam Number',
          reqd: true,
          dependsOn: 'eval:doc.is_msme==1',
        ),
      ],
    );
    final form = await pumpForm(
      tester,
      meta,
      initialData: const {'is_msme': 0},
    );

    form.submit();
    await tester.pumpAndSettle();

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
  });

  testWidgets('numeric zero counts as filled (Frappe parity)', (tester) async {
    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'tab_basic',
          fieldtype: 'Tab Break',
          idx: 1,
          label: 'Basic',
        ),
        DocField(fieldname: 'note', fieldtype: 'Data', idx: 2, label: 'Note'),
        DocField(
          fieldname: 'tab_details',
          fieldtype: 'Tab Break',
          idx: 3,
          label: 'Details',
        ),
        DocField(
          fieldname: 'employee_count',
          fieldtype: 'Int',
          idx: 4,
          label: 'Employee Count',
          reqd: true,
        ),
      ],
    );
    final form = await pumpForm(
      tester,
      meta,
      initialData: const {'employee_count': 0},
    );

    form.submit();
    await tester.pumpAndSettle();

    expect(form.failed, isEmpty);
    expect(form.submitted, hasLength(1));
  });
}
