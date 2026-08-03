import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart'
    show ChangeSource;

/// Verifies form/field lifecycle hooks fire correctly for CHILD-TABLE rows,
/// driven through the real add-row dialog (so it exercises the parent's
/// `childTableFormBuilder` forwarding, not a standalone child builder):
///  - `onFieldChange` fires for a child-row field, with the child field name;
///  - `cascadeProgrammaticChanges` is forwarded into the child row (PR#83 #2),
///    so a chained compute (qty→amount→label) cascades inside the child;
///  - a child field hidden by its own `depends_on` is stripped from the child
///    row's submit payload (same `_handleSubmit` as the parent).
///
/// The parent form here is LEGACY mode (default), so the child row also renders
/// legacy and goes through the extracted `_onFieldValueChanged` — the exact
/// path the computed-field-cascade merge changed.
void main() {
  DocTypeMeta parentMeta() => DocTypeMeta(
    name: 'Parent',
    fields: <DocField>[
      DocField(
        fieldname: 'items',
        fieldtype: 'Table',
        label: 'Items',
        options: 'ItemDT',
      ),
    ],
  );

  DocTypeMeta childMeta() => DocTypeMeta(
    name: 'ItemDT',
    fields: <DocField>[
      DocField(fieldname: 'qty', fieldtype: 'Data', label: 'Qty'),
      DocField(fieldname: 'amount', fieldtype: 'Data', label: 'Amount'),
      DocField(fieldname: 'label', fieldtype: 'Data', label: 'Label'),
      // Hidden unless qty == 'never' — so with qty='5' it must be stripped.
      DocField(
        fieldname: 'secret',
        fieldtype: 'Data',
        label: 'Secret',
        dependsOn: 'eval:doc.qty=="never"',
      ),
    ],
  );

  testWidgets(
    'child-row field change fires onFieldChange, cascades via the parent flag, '
    'and strips a hidden child field on submit',
    (tester) async {
      final seen = <String>[];
      Map<String, dynamic>? parentData;

      Map<String, dynamic>? handler(
        String name,
        dynamic value,
        Map<String, dynamic> data, {
        ChangeSource source = ChangeSource.user,
      }) {
        seen.add(name);
        if (name == 'qty') return {'amount': 'A:$value'};
        if (name == 'amount') return {'label': 'L:$value'};
        return null;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: parentMeta(),
              getMeta: (_) async => childMeta(),
              cascadeProgrammaticChanges: true, // must reach the child row
              onFieldChange: handler,
              onFormDataChanged: (d) => parentData = d,
            ),
          ),
        ),
      );

      // Open the child-row add dialog. getMeta is async + the sheet animates,
      // so pump (not pumpAndSettle — the SDK form inside the modal never fully
      // settles in a unit test).
      await tester.tap(find.text('Add Row'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Change a field INSIDE the child row.
      await tester.enterText(find.byKey(const ValueKey('data_qty')), '5');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Lifecycle: onFieldChange fired for the child field...
      expect(
        seen.contains('qty'),
        isTrue,
        reason: 'child-row onFieldChange must fire for qty',
      );
      // ...and the cascade flag reached the child (amount re-fired → label).
      expect(
        seen.contains('amount'),
        isTrue,
        reason: 'cascadeProgrammaticChanges must be forwarded to the child row',
      );
      expect(find.byKey(const ValueKey('data_amount')), findsOneWidget);

      // Save the child row → merges back into the parent's `items`.
      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final items = (parentData?['items'] as List?) ?? const [];
      expect(items, isNotEmpty, reason: 'the child row must be saved');
      final row = Map<String, dynamic>.from(items.first as Map);

      expect(row['amount'], 'A:5', reason: 'computed child field persists');
      expect(
        row.containsKey('secret'),
        isFalse,
        reason:
            'child field hidden by its depends_on must be stripped on submit',
      );
    },
  );
}
