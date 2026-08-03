import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

void main() {
  test('debug tracing logs changed + affected fields', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (m, {wrapWidth}) => logs.add(m ?? '');
    final c = FormController(
      meta: DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 'g', fieldtype: 'Check'),
          DocField(
            fieldname: 'd',
            fieldtype: 'Data',
            dependsOn: 'eval:doc.g == 1',
          ),
        ],
      ),
    )..enableDebugTracing();
    c.setValue('g', 1);
    await Future.microtask(() {});
    debugPrint = original;
    expect(logs.any((l) => l.contains('g') && l.contains('d')), true);
    c.dispose();
  });

  test('no trace output when tracing is off', () {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (m, {wrapWidth}) => logs.add(m ?? '');
    final c = FormController(
      meta: DocTypeMeta(
        name: 'T',
        fields: [DocField(fieldname: 'a', fieldtype: 'Data')],
      ),
    );
    c.setValue('a', 'x');
    debugPrint = original;
    expect(logs, isEmpty);
    c.dispose();
  });
}
