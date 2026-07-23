import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test(
    'reset re-emits submitData, clears errors, resets activeTab, keeps notifier identity',
    () {
      final c = FormController(
        meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
        initialData: {'a': '1'},
      );
      final aValueNotifier = c.valueOf('a');
      c.setValue('a', '');
      c.validate();
      expect(c.invalidFields.containsKey('a'), true);
      c.reset(initialData: {'a': '2'});
      expect(
        identical(c.valueOf('a'), aValueNotifier),
        true,
      ); // identity preserved
      expect(c.getValue('a'), '2');
      expect(c.invalidFields, isEmpty); // errors cleared
      expect(c.errorListenableOf('a').value, isNull);
      expect(c.activeTab.value, 0); // reset
      expect(c.submitData.value['a'], '2'); // re-emitted
      expect(c.isDirty.value, false);
      c.dispose();
    },
  );

  test(
    'reset(meta) disposes + drops focus nodes for removed fields (no leak)',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'a', fieldtype: 'Data'),
          DocField(fieldname: 'gone', fieldtype: 'Data'),
        ]),
      );
      final goneNode = c.focusNodeOf('gone'); // created on demand
      c.reset(
        meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
      ); // 'gone' removed
      // The removed field's node was disposed + dropped: requesting it yields a NEW instance.
      expect(identical(c.focusNodeOf('gone'), goneNode), false);
      c.dispose();
    },
  );
}
