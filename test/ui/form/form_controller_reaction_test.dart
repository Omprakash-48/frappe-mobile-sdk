import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test(
    'setValue with ChangeSource sets the value; fromUser alias maps to user',
    () {
      final c = FormController(
        meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
      );
      c.setValue('a', 'x', source: ChangeSource.user);
      expect(c.getValue('a'), 'x');
      // ignore: deprecated_member_use_from_same_package
      c.setValue(
        'a',
        'y',
        fromUser: true,
      ); // deprecated alias still compiles + works
      expect(c.getValue('a'), 'y');
      c.dispose();
    },
  );

  test(
    'reaction fires for user/programmatic changes and patches in same flush',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(fieldname: 'total', fieldtype: 'Int'),
        ]),
      );
      c.onFieldReaction = (name, value, data) =>
          name == 'qty' ? {'total': (value as int) * 2} : null;
      c.setValue('qty', 5, source: ChangeSource.user);
      expect(c.getValue('total'), 10); // computed in the same flush
      c.dispose();
    },
  );

  test(
    'reaction does NOT fire for reaction/system-sourced writes (loop-free)',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'a', fieldtype: 'Int'),
          DocField(fieldname: 'b', fieldtype: 'Int'),
        ]),
      );
      var calls = 0;
      c.onFieldReaction = (name, value, data) {
        calls++;
        return name == 'a'
            ? {'b': 1}
            : null; // b is reaction-sourced -> no re-fire
      };
      c.setValue('a', 1, source: ChangeSource.user);
      expect(calls, 1); // only 'a' fired
      expect(c.getValue('b'), 1);
      c.dispose();
    },
  );

  test(
    'flush-completion invariant: exactly one notifyListeners per setValue',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'a', fieldtype: 'Data'),
          DocField(
            fieldname: 'b',
            fieldtype: 'Data',
            dependsOn: 'eval:doc.a == "x"',
          ),
        ]),
      );
      var n = 0;
      c.addListener(() => n++);
      c.setValue('a', 'x', source: ChangeSource.user);
      expect(
        n,
        1,
      ); // single coalesced notification despite b's uiState recompute
      c.dispose();
    },
  );
}
