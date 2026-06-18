import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('seeds defaults including Date "today"', () {
    final c = FormController(
      meta: _meta([
        DocField(
          fieldname: 'visit_date',
          fieldtype: 'Date',
          defaultValue: 'Today',
        ),
        DocField(fieldname: 'kind', fieldtype: 'Select', defaultValue: 'A'),
      ]),
      now: () => DateTime(2026, 6, 17),
    );
    expect(c.getValue('visit_date'), '2026-06-17');
    expect(c.getValue('kind'), 'A');
    c.dispose();
  });

  test('initialData overrides defaults', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'kind', fieldtype: 'Select', defaultValue: 'A'),
      ]),
      initialData: {'kind': 'B'},
    );
    expect(c.getValue('kind'), 'B');
    c.dispose();
  });

  test(
    'setValue updates value and notifies valueOf listener only for that field',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'a', fieldtype: 'Data'),
          DocField(fieldname: 'b', fieldtype: 'Data'),
        ]),
      );
      var aHits = 0, bHits = 0;
      c.valueOf('a').addListener(() => aHits++);
      c.valueOf('b').addListener(() => bHits++);
      c.setValue('a', 'x');
      expect(c.getValue('a'), 'x');
      expect(aHits, 1);
      expect(bHits, 0);
      c.dispose();
    },
  );

  test('uiStateOf is the shared editable instance for static fields', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
    );
    expect(c.uiStateOf('a').value.visible, true);
    c.dispose();
  });
}
