import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test(
    'not dirty at start; dirty after change; clean again after revert',
    () async {
      final c = FormController(
        meta: _meta([DocField(fieldname: 'a', fieldtype: 'Int')]),
        initialData: {'a': 1},
      );
      expect(c.isDirty.value, false);
      c.setValue('a', 2);
      await Future.microtask(() {});
      expect(c.isDirty.value, true);
      c.setValue('a', 1); // revert
      await Future.microtask(() {});
      expect(c.isDirty.value, false); // 1 -> 2 -> 1 ends clean
      c.dispose();
    },
  );

  test('markPristine rebaselines current values', () async {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Int')]),
      initialData: {'a': 1},
    );
    c.setValue('a', 9);
    await Future.microtask(() {});
    expect(c.isDirty.value, true);
    c.markPristine();
    expect(c.isDirty.value, false);
    c.dispose();
  });
}
