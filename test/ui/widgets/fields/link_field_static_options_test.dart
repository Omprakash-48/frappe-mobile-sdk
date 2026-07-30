// Covers the LinkField "static options" branch — when the host passes a
// pre-resolved [options] list instead of a LinkOptionService. This path is
// used by the LinkSelect field type and by certain custom factories.
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/link_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  List<String>? options,
  dynamic value,
  ValueChanged<dynamic>? onChanged,
  GlobalKey<FormBuilderState>? formKey,
}) async {
  final key = formKey ?? GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: key,
          child: LinkField(
            field: field,
            value: value,
            onChanged: onChanged,
            options: options,
          ),
        ),
      ),
    ),
  );
}

void main() {
  final field = DocField(
    fieldname: 'state',
    fieldtype: 'Link',
    label: 'State',
    options: 'State',
  );

  testWidgets('static options render as DropdownMenuItems', (tester) async {
    await _pump(tester, field: field, options: const ['TN', 'KL', 'KA']);
    final w = tester.widget<FormBuilderDropdown<String>>(
      find.byType(FormBuilderDropdown<String>),
    );
    expect(w.items, hasLength(3));
  });

  testWidgets('initial value is preserved when in options', (tester) async {
    await _pump(tester, field: field, value: 'KL', options: const ['TN', 'KL']);
    expect(find.text('KL'), findsOneWidget);
  });

  testWidgets('initial value not in options falls back to null', (
    tester,
  ) async {
    await _pump(
      tester,
      field: field,
      value: 'Stale',
      options: const ['TN', 'KL'],
    );
    expect(find.text('Stale'), findsNothing);
    expect(find.text('Select State'), findsOneWidget);
  });

  testWidgets('exactly one option auto-selects and emits onChanged', (
    tester,
  ) async {
    String? emitted;
    await _pump(
      tester,
      field: field,
      options: const ['Single'],
      onChanged: (v) => emitted = v as String?,
    );
    await tester.pump();
    expect(emitted, 'Single');
  });

  testWidgets('required validator catches empty submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'state',
        fieldtype: 'Link',
        label: 'State',
        options: 'State',
        reqd: true,
      ),
      options: const ['TN', 'KL'],
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('State is required'), findsOneWidget);
  });

  testWidgets('readOnly disables the dropdown', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'state',
        fieldtype: 'Link',
        label: 'State',
        options: 'State',
        readOnly: true,
      ),
      value: 'TN',
      options: const ['TN', 'KL'],
    );
    final w = tester.widget<FormBuilderDropdown<String>>(
      find.byType(FormBuilderDropdown<String>),
    );
    expect(w.enabled, isFalse);
  });

  testWidgets('placeholder overrides default hint when set', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'state',
        fieldtype: 'Link',
        label: 'State',
        options: 'State',
        placeholder: 'Pick your state',
      ),
      options: const ['TN', 'KL'],
    );
    expect(find.text('Pick your state'), findsOneWidget);
  });

  // Mirrors the SelectField "full-field tap target" group. The static-options
  // LinkField applies the same [dropdownFullTap] redistribution, so the whole
  // bordered box — including the padding margins that used to be a dead zone —
  // must open the menu.
  group('full-field tap target', () {
    const styledDecoration = InputDecoration(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    Future<void> pumpStyled(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              child: LinkField(
                field: field,
                options: const ['TN', 'KL', 'KA'],
                style: const FieldStyle(decoration: styledDecoration),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tap on the left padding margin opens the menu', (
      tester,
    ) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      // 8px in from the left border — inside the old 16px dead margin.
      await tester.tapAt(Offset(box.left + 8, box.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('KL'), findsOneWidget, reason: 'menu should open');
    });

    testWidgets('tap on the center still opens the menu', (tester) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      await tester.tapAt(box.center);
      await tester.pumpAndSettle();
      expect(find.text('KL'), findsOneWidget);
    });

    testWidgets('tap near the top edge opens the menu', (tester) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      // 4px below the top border — inside the old vertical padding dead zone.
      await tester.tapAt(Offset(box.center.dx, box.top + 4));
      await tester.pumpAndSettle();
      expect(
        find.text('KL'),
        findsOneWidget,
        reason: 'top edge must be tappable',
      );
    });

    testWidgets('tap near the bottom edge opens the menu', (tester) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      await tester.tapAt(Offset(box.center.dx, box.bottom - 4));
      await tester.pumpAndSettle();
      expect(
        find.text('KL'),
        findsOneWidget,
        reason: 'bottom edge must be tappable',
      );
    });
  });
}
