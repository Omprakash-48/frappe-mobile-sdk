import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('changing a gate flips a dependent field visibility', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'marital_status', fieldtype: 'Select'),
        DocField(
          fieldname: 'spouse',
          fieldtype: 'Data',
          dependsOn: 'eval:doc.marital_status == "Married"',
        ),
      ]),
    );
    expect(c.uiStateOf('spouse').value.visible, false);
    c.setValue('marital_status', 'Married');
    expect(c.uiStateOf('spouse').value.visible, true);
    c.dispose();
  });

  test('hiding a field clears its value (Yes->No->Yes comes back empty)', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'married', fieldtype: 'Check'),
        DocField(
          fieldname: 'spouse',
          fieldtype: 'Data',
          dependsOn: 'eval:doc.married == 1',
        ),
      ]),
    );
    c.setValue('married', 1);
    c.setValue('spouse', 'Pat');
    expect(c.getValue('spouse'), 'Pat');
    c.setValue('married', 0); // hide -> clear
    expect(c.getValue('spouse'), isNull);
    c.setValue('married', 1); // re-show -> still empty
    expect(c.getValue('spouse'), isNull);
    c.dispose();
  });

  test('link_filters dependent field is cleared when its source changes', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'state', fieldtype: 'Link', options: 'State'),
        DocField(
          fieldname: 'district',
          fieldtype: 'Link',
          options: 'District',
          linkFilters: 'eval:doc.state',
        ),
      ]),
    );
    c.setValue('district', 'D1');
    c.setValue('state', 'S2');
    expect(c.getValue('district'), isNull);
    c.dispose();
  });

  test('batch() runs one notification round for many mutations', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'a', fieldtype: 'Data'),
        DocField(fieldname: 'b', fieldtype: 'Data'),
        DocField(fieldname: 'c', fieldtype: 'Data'),
      ]),
    );
    var formHits = 0;
    c.addListener(() => formHits++);
    c.batch(() {
      c.setValue('a', '1');
      c.setValue('b', '2');
      c.setValue('c', '3');
    });
    expect(formHits, 1);
    c.dispose();
  });

  test(
    'transitive visibility clear cascades through N levels (A->B->C->D)',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'a', fieldtype: 'Int'),
          DocField(
            fieldname: 'b',
            fieldtype: 'Int',
            dependsOn: 'eval:doc.a > 10',
          ),
          DocField(
            fieldname: 'c',
            fieldtype: 'Int',
            dependsOn: 'eval:doc.b > 20',
          ),
          DocField(
            fieldname: 'd',
            fieldtype: 'Int',
            dependsOn: 'eval:doc.c > 30',
          ),
        ]),
      );
      c.setValue('a', 20);
      c.setValue('b', 30);
      c.setValue('c', 40);
      c.setValue('d', 50);
      expect(c.uiStateOf('d').value.visible, true);

      c.setValue('a', 5); // collapse the whole chain in one flush
      for (final f in ['b', 'c', 'd']) {
        expect(
          c.uiStateOf(f).value.visible,
          false,
          reason: '$f should be hidden',
        );
        expect(c.getValue(f), isNull, reason: '$f should be cleared');
      }
      c.dispose();
    },
  );
}
