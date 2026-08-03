import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  group('depends_on evaluation scope', () {
    test('parent.<field> resolves from parentData on a child-row form', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'qty': '1'},
        parentData: const {'kind': 'X'},
      );
      expect(c.uiStateOf('gated').value.visible, isTrue);
    });

    test('parent.<field> that does not match hides the field', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'qty': '1'},
        parentData: const {'kind': 'Y'},
      );
      expect(c.uiStateOf('gated').value.visible, isFalse);
    });

    test('mandatory_depends_on can read parent', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'reason',
            fieldtype: 'Data',
            mandatoryDependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        parentData: const {'kind': 'X'},
      );
      expect(c.uiStateOf('reason').value.required, isTrue);
    });

    test('with no parentData, parent aliases doc (as Frappe does)', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'kind', fieldtype: 'Data'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'kind': 'X'},
      );
      expect(c.uiStateOf('gated').value.visible, isTrue);
    });

    test('std fields (docstatus) are readable by depends_on', () {
      // docstatus is not in DocType.fields, so _seedDefaults would drop it and
      // `eval:doc.docstatus == 0` would hide a field Desk shows. The legacy
      // _formData path carries it via addAll(initialData); reactive mode must
      // match.
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'x', fieldtype: 'Data'),
          DocField(
            fieldname: 'draft_only',
            fieldtype: 'Data',
            dependsOn: 'eval:doc.docstatus == 0',
          ),
        ]),
        initialData: const {'x': '1', 'docstatus': 0},
      );
      expect(c.uiStateOf('draft_only').value.visible, isTrue);

      final submitted = FormController(
        meta: _meta([
          DocField(fieldname: 'x', fieldtype: 'Data'),
          DocField(
            fieldname: 'draft_only',
            fieldtype: 'Data',
            dependsOn: 'eval:doc.docstatus == 0',
          ),
        ]),
        initialData: const {'x': '1', 'docstatus': 1},
      );
      expect(submitted.uiStateOf('draft_only').value.visible, isFalse);
    });

    test('std fields stay OUT of the submit payload', () {
      final c = FormController(
        meta: _meta([DocField(fieldname: 'x', fieldtype: 'Data')]),
        initialData: const {
          'x': '1',
          'docstatus': 0,
          'name': 'T-0001',
          'owner': 'a@b.c',
          '__islocal': 1,
        },
      );
      final payload = c.buildSubmitData();
      expect(payload.containsKey('x'), isTrue);
      for (final k in ['docstatus', 'name', 'owner', '__islocal']) {
        expect(payload.containsKey(k), isFalse, reason: '$k leaked into save');
      }
    });
  });
}
