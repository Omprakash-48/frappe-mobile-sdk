import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

void main() {
  test(
    'submit payload excludes hidden-by-depends_on and fills visible defaults',
    () {
      final c = FormController(
        meta: DocTypeMeta(
          name: 'T',
          fields: [
            DocField(fieldname: 'married', fieldtype: 'Check'),
            DocField(
              fieldname: 'spouse',
              fieldtype: 'Data',
              dependsOn: 'eval:doc.married == 1',
            ),
            DocField(fieldname: 'notes', fieldtype: 'Data'),
          ],
        ),
        initialData: {'married': 0},
      );
      final out = c.buildSubmitData();
      expect(out.containsKey('spouse'), false); // hidden -> excluded
      expect(out.containsKey('married'), true);
      expect(
        out.containsKey('notes'),
        true,
      ); // visible -> present (empty string)
      c.dispose();
    },
  );

  test('hidden-by-section-break depends_on is excluded', () {
    final c = FormController(
      meta: DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 'show', fieldtype: 'Check'),
          DocField(fieldtype: 'Section Break', dependsOn: 'eval:doc.show == 1'),
          DocField(fieldname: 'secret', fieldtype: 'Data'),
        ],
      ),
      initialData: {'show': 0},
    );
    expect(c.buildSubmitData().containsKey('secret'), false);
    c.dispose();
  });
}
