import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('required (reqd) fails validate() when empty, passes when filled', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
    );
    expect(c.validate(), false);
    expect(c.errorOf('a'), isNotNull);
    c.setValue('a', 'x');
    expect(c.validate(), true);
    expect(c.errorOf('a'), isNull);
    c.dispose();
  });

  test('reqd takes priority over a registered field validator', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
    );
    c.addFieldValidator('a', (v, _) => 'always-bad');
    c.validate();
    expect(c.errorOf('a'), contains('required')); // reqd wins on empty
    c.dispose();
  });

  test('cross-field validator surfaces an error keyed by field', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'min', fieldtype: 'Int'),
        DocField(fieldname: 'max', fieldtype: 'Int'),
      ]),
    );
    c.addCrossFieldValidator((d) {
      final lo = d['min'], hi = d['max'];
      if (lo != null && hi != null && (lo as num) > (hi as num)) {
        return {'max': 'max < min'};
      }
      return null;
    });
    c.setValue('min', 5);
    c.setValue('max', 3);
    expect(c.validate(), false);
    expect(c.errorOf('max'), 'max < min');
    c.dispose();
  });

  test('validateAsync awaits async validators', () async {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'code', fieldtype: 'Data')]),
    );
    c.addAsyncFieldValidator(
      'code',
      (v, _) async => v == 'taken' ? 'duplicate' : null,
    );
    c.setValue('code', 'taken');
    expect(await c.validateAsync(), false);
    expect(c.errorOf('code'), 'duplicate');
    c.dispose();
  });
}
