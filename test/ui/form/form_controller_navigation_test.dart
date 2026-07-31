import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('tabs derived from Tab Break; tabIndexOf maps field to tab', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'a', fieldtype: 'Data'),
        DocField(fieldtype: 'Tab Break', label: 'Tab2'),
        DocField(fieldname: 'b', fieldtype: 'Data'),
      ]),
    );
    expect(c.tabs.length, 2);
    expect(c.tabIndexOf('a'), 0);
    expect(c.tabIndexOf('b'), 1);
    c.dispose();
  });

  test('goToTab updates activeTab and short-circuits a redundant set', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'a', fieldtype: 'Data'),
        DocField(fieldtype: 'Tab Break', label: 'Tab2'),
        DocField(fieldname: 'b', fieldtype: 'Data'),
      ]),
    );
    var hits = 0;
    c.activeTab.addListener(() => hits++);
    c.goToTab(0); // already 0 -> no-op
    expect(hits, 0);
    c.goToTab(1);
    expect(hits, 1);
    expect(c.activeTab.value, 1);
    c.dispose();
  });

  test('requestScrollToField emits on scrollRequests', () async {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
    );
    final f = c.scrollRequests.first;
    c.requestScrollToField('a');
    expect(await f, 'a');
    c.dispose();
  });
}
