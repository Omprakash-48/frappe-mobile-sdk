import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('focusNode is lazily created and stable per field', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
    );
    final n1 = c.focusNodeOf('a');
    final n2 = c.focusNodeOf('a');
    expect(identical(n1, n2), true);
    expect(n1, isA<FocusNode>());
    c.dispose();
  });

  test('reset preserves notifier identity for surviving fields', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
      initialData: {'a': '1'},
    );
    final before = c.valueOf('a');
    c.reset(initialData: {'a': '2'});
    expect(identical(c.valueOf('a'), before), true); // same notifier instance
    expect(c.getValue('a'), '2');
    c.dispose();
  });
}
