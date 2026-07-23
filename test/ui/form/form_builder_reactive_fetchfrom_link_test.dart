// Regression: in reactive mode, fetch_from must populate its target fields in
// the FormController (the single source of truth that drives the submit
// payload and reactive Link rendering).
//
// Before the fix, prefilled (edit-form) fetch_from was routed through the
// legacy `_handleFetchFrom`, which only patched flutter_form_builder field
// state. Data targets *appeared* populated via that leaked field state, but
// reactive Link targets — which read their value from the controller — stayed
// empty, and the submit payload missed every fetched value.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

class _ScriptedLinkOptionService extends LinkOptionService {
  final Map<String, List<LinkOptionEntity>> byDoctype;
  _ScriptedLinkOptionService(this.byDoctype) : super.withoutResolver();
  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async => byDoctype[doctype] ?? const [];
}

LinkOptionEntity _opt(String dt, String name) =>
    LinkOptionEntity(doctype: dt, name: name, label: name, lastUpdated: 0);

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  fields: [
    DocField(
      fieldname: 'patient',
      fieldtype: 'Link',
      options: 'Patient',
      label: 'Patient',
    ),
    DocField(
      fieldname: 'pname',
      fieldtype: 'Data',
      fetchFrom: 'patient.full_name',
      label: 'Patient Name',
    ),
    DocField(
      fieldname: 'doctor',
      fieldtype: 'Link',
      options: 'Doctor',
      fetchFrom: 'patient.primary_doctor',
      label: 'Doctor',
    ),
  ],
);

Future<Map<String, dynamic>?> _fetch(String doctype, String name) async {
  if (doctype == 'Patient' && name == 'P1') {
    return {'full_name': 'Alice', 'primary_doctor': 'DR-001'};
  }
  return null;
}

LinkOptionService _svc() => _ScriptedLinkOptionService({
  'Patient': [_opt('Patient', 'P1')],
  'Doctor': [_opt('Doctor', 'DR-001'), _opt('Doctor', 'DR-002')],
});

Widget _form(DocTypeMeta meta, FormController controller) => MaterialApp(
  home: Scaffold(
    body: FrappeFormBuilder(
      meta: meta,
      mode: FormBuilderMode.reactive,
      controller: controller,
      linkOptionService: _svc(),
      useLinkFieldCoordinator: false,
      fetchLinkedDocument: _fetch,
    ),
  ),
);

void main() {
  testWidgets(
    'prefilled edit-form: fetch_from runs into the controller (Data + Link targets)',
    (tester) async {
      final meta = _meta();
      final controller = FormController(
        meta: meta,
        initialData: const {'patient': 'P1'},
      );
      await tester.pumpWidget(_form(meta, controller));
      await tester.pumpAndSettle();

      // Controller is the single source of truth and drives the submit payload.
      expect(
        controller.getValue('pname'),
        'Alice',
        reason: 'Data target populated in controller',
      );
      expect(
        controller.getValue('doctor'),
        'DR-001',
        reason: 'Link target populated in controller',
      );
      final submit = controller.buildSubmitData();
      expect(submit['pname'], 'Alice');
      expect(submit['doctor'], 'DR-001');

      // Reactive Link target renders its fetched value from the controller.
      expect(find.text('DR-001'), findsOneWidget);

      controller.dispose();
    },
  );

  testWidgets(
    'on-change: selecting the source Link populates targets in the controller',
    (tester) async {
      final meta = _meta();
      final controller = FormController(meta: meta);
      await tester.pumpWidget(_form(meta, controller));
      await tester.pumpAndSettle();

      controller.setValue('patient', 'P1', source: ChangeSource.user);
      await tester.pumpAndSettle();

      expect(controller.getValue('pname'), 'Alice');
      expect(controller.getValue('doctor'), 'DR-001');
      final submit = controller.buildSubmitData();
      expect(submit['pname'], 'Alice');
      expect(submit['doctor'], 'DR-001');
      expect(find.text('DR-001'), findsOneWidget);

      controller.dispose();
    },
  );
}
