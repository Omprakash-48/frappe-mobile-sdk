import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test(
    'errorListenableOf updates on validate; invalidFields lists failures',
    () {
      final c = FormController(
        meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
      );
      var hits = 0;
      c.errorListenableOf('a').addListener(() => hits++);
      expect(c.validate(), false);
      expect(c.errorListenableOf('a').value, isNotNull);
      expect(c.invalidFields.containsKey('a'), true);
      expect(hits >= 1, true);
      c.setValue('a', 'x');
      expect(c.validate(), true);
      expect(c.errorListenableOf('a').value, isNull);
      expect(c.invalidFields, isEmpty);
      c.dispose();
    },
  );

  test('validateField validates one field only', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'a', fieldtype: 'Data', reqd: true),
        DocField(fieldname: 'b', fieldtype: 'Data', reqd: true),
      ]),
    );
    expect(c.validateField('a'), false);
    expect(c.errorListenableOf('a').value, isNotNull);
    expect(c.errorListenableOf('b').value, isNull); // b untouched
    c.dispose();
  });

  test('stale async-validator result is discarded (latest wins)', () async {
    final gates = <String, Completer<String?>>{};
    final c = FormController(
      meta: _meta([DocField(fieldname: 'code', fieldtype: 'Data')]),
    );
    c.addAsyncFieldValidator('code', (v, _) {
      final comp = Completer<String?>();
      gates[v as String] = comp;
      return comp.future;
    });
    c.setValue('code', 'A');
    final fA = c.validateAsync(); // dispatch for 'A'
    c.setValue('code', 'B');
    final fB = c.validateAsync(); // dispatch for 'B' (latest)
    gates['B']!.complete(null); // B valid
    gates['A']!.complete('dup-A'); // A invalid, resolves last (stale)
    await fA;
    await fB;
    expect(c.errorOf('code'), isNull); // stale 'A' error discarded
    c.dispose();
  });
}
