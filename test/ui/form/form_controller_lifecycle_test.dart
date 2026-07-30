import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  test('reportFieldMounted/Unmounted drive the lifecycle stream', () async {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'd', fieldtype: 'Data')]),
    );
    final events = <FieldLifecycleKind>[];
    c.fieldLifecycle
        .where((e) => e.field == 'd')
        .listen((e) => events.add(e.kind));
    c.reportFieldMounted('d');
    c.reportFieldUnmounted('d');
    await Future.delayed(Duration.zero);
    expect(events, [FieldLifecycleKind.mounted, FieldLifecycleKind.unmounted]);
    c.dispose();
  });

  testWidgets('focusGained emitted from the field focus node', (tester) async {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data')]),
    );
    final kinds = <FieldLifecycleKind>[];
    c.fieldLifecycle
        .where((e) => e.field == 'a')
        .listen((e) => kinds.add(e.kind));
    final node = c.focusNodeOf('a');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(focusNode: node, child: const SizedBox()),
        ),
      ),
    );
    node.requestFocus();
    await tester.pump();
    expect(kinds.contains(FieldLifecycleKind.focusGained), true);
    c.dispose();
  });
}
