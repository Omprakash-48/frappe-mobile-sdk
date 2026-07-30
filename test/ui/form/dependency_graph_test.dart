import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/dependency_graph.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('depends_on creates a UI dependent edge', () {
    final g = DependencyGraph.build(
      _meta([
        DocField(fieldname: 'marital_status', fieldtype: 'Select'),
        DocField(
          fieldname: 'spouse',
          fieldtype: 'Data',
          dependsOn: 'eval:doc.marital_status == "Married"',
        ),
      ]),
    );
    expect(g.affectedBy('marital_status'), contains('spouse'));
  });

  test('fetch_from creates a fetch-target edge', () {
    final g = DependencyGraph.build(
      _meta([
        DocField(fieldname: 'patient', fieldtype: 'Link', options: 'Patient'),
        DocField(
          fieldname: 'patient_name',
          fieldtype: 'Data',
          fetchFrom: 'patient.full_name',
        ),
      ]),
    );
    expect(g.fetchTargetsOf('patient'), contains('patient_name'));
    expect(g.affectedBy('patient'), contains('patient_name'));
  });

  test('link_filters eval:doc.X creates a clear edge', () {
    final g = DependencyGraph.build(
      _meta([
        DocField(fieldname: 'state', fieldtype: 'Link', options: 'State'),
        DocField(
          fieldname: 'district',
          fieldtype: 'Link',
          options: 'District',
          linkFilters: 'eval:doc.state',
        ),
      ]),
    );
    expect(g.linkClearsOf('state'), contains('district'));
  });

  test('unparseable expression -> owner subscribes to all changes', () {
    final g = DependencyGraph.build(
      _meta([
        DocField(fieldname: 'a', fieldtype: 'Data'),
        DocField(
          fieldname: 'weird',
          fieldtype: 'Data',
          dependsOn: 'eval:frappe.some_fn() > 0',
        ), // no doc.<field>
      ]),
    );
    expect(g.affectedBy('a'), contains('weird')); // via fallbackAll
  });

  test('detects a fetch_from value cycle', () {
    final g = DependencyGraph.build(
      _meta([
        DocField(fieldname: 'a', fieldtype: 'Data', fetchFrom: 'b.x'),
        DocField(fieldname: 'b', fieldtype: 'Data', fetchFrom: 'a.y'),
      ]),
    );
    expect(g.valueCycles, isNotEmpty);
    expect(() => g.assertNoValueCycles(), throwsA(isA<AssertionError>()));
  });

  test('mutual depends_on is NOT a value cycle (UI-only, converges)', () {
    final g = DependencyGraph.build(
      _meta([
        DocField(fieldname: 'a', fieldtype: 'Data', dependsOn: 'eval:doc.b'),
        DocField(fieldname: 'b', fieldtype: 'Data', dependsOn: 'eval:doc.a'),
      ]),
    );
    expect(g.valueCycles, isEmpty);
    g.assertNoValueCycles(); // does not throw
  });
}
