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
      c.onFieldReaction =
          (name, value, data, {ChangeSource source = ChangeSource.user}) =>
              name == 'qty' ? {'total': (value as int) * 2} : null;
      c.setValue('qty', 5, source: ChangeSource.user);
      expect(c.getValue('total'), 10); // computed in the same flush
      c.dispose();
    },
  );

  test('reaction-sourced patches do NOT re-fire the reaction (loop-free)', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'a', fieldtype: 'Int'),
        DocField(fieldname: 'b', fieldtype: 'Int'),
      ]),
    );
    var calls = 0;
    c.onFieldReaction =
        (name, value, data, {ChangeSource source = ChangeSource.user}) {
          calls++;
          return name == 'a'
              ? {'b': 1}
              : null; // b is reaction-sourced -> no re-fire
        };
    c.setValue('a', 1, source: ChangeSource.user);
    expect(calls, 1); // only 'a' fired
    expect(c.getValue('b'), 1);
    c.dispose();
  });

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

  test('system-sourced change (fetch_from sim) recomputes its dependent', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'src', fieldtype: 'Data'),
        DocField(fieldname: 'derived', fieldtype: 'Data'),
      ]),
    );
    final fired = <String>[];
    c.onFieldReaction =
        (name, value, data, {ChangeSource source = ChangeSource.user}) {
          fired.add('$name:$source');
          return name == 'src' ? {'derived': '$value!'} : null;
        };
    c.setValue('src', 'X', source: ChangeSource.system); // simulate fetch_from
    expect(c.getValue('derived'), 'X!'); // recomputed despite system source
    expect(fired, contains('src:ChangeSource.system'));
    c.dispose();
  });

  test('clear-on-hide of a computed source converges (no oscillation)', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'gate', fieldtype: 'Data'),
        DocField(
          fieldname: 'shown',
          fieldtype: 'Data',
          dependsOn: 'eval:doc.gate == "on"',
        ),
      ]),
    );
    c.onFieldReaction =
        (name, value, data, {ChangeSource source = ChangeSource.user}) =>
            (name == 'gate' && value == 'on') ? {'shown': 'visible'} : null;
    c.setValue('gate', 'on', source: ChangeSource.user);
    expect(c.getValue('shown'), 'visible');
    // Turning the gate off hides 'shown' -> cleared (system). With system now
    // firing reactions, 'shown' reacts (returns null) -> converges, no hang.
    c.setValue('gate', 'off', source: ChangeSource.user);
    expect(c.getValue('shown'), isNull);
    c.dispose();
  });
}
