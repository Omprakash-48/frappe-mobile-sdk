import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('stale fetch_from response is discarded (latest wins)', () async {
    final completers = <String, Completer<Map<String, dynamic>?>>{};
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'patient', fieldtype: 'Link', options: 'Patient'),
        DocField(
          fieldname: 'pname',
          fieldtype: 'Data',
          fetchFrom: 'patient.full_name',
        ),
      ]),
    );
    c.fetchLinkedDocument = (doctype, name) {
      final comp = Completer<Map<String, dynamic>?>();
      completers[name] = comp;
      return comp.future;
    };
    c.setValue('patient', 'P1', source: ChangeSource.user); // dispatch #1
    c.setValue(
      'patient',
      'P2',
      source: ChangeSource.user,
    ); // dispatch #2 (latest)
    completers['P2']!.complete({'full_name': 'Two'});
    completers['P1']!.complete({'full_name': 'One'}); // stale, arrives last
    await Future.delayed(Duration.zero);
    expect(c.getValue('pname'), 'Two'); // stale P1 discarded
    c.dispose();
  });
}
