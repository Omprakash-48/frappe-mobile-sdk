import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('submitData updates once per flush with buildSubmitData content', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'a', fieldtype: 'Data'),
        DocField(fieldname: 'b', fieldtype: 'Data'),
      ]),
    );
    var hits = 0;
    c.submitData.addListener(() => hits++);
    c.batch(() {
      c.setValue('a', '1');
      c.setValue('b', '2');
    });
    expect(hits, 1); // one flush -> one emit
    expect(c.submitData.value['a'], '1');
    expect(c.submitData.value['b'], '2');
    c.dispose();
  });
}
