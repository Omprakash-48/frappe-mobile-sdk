import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';

FieldStyle _styleWithTranslate(String Function(String) t) =>
    FieldStyle(translate: t);

DocField _field({String options = 'Yes\nNo\nMaybe'}) => DocField(
      fieldname: 'test_field',
      fieldtype: 'Select',
      label: 'Test',
      options: options,
    );

/// Extracts display text from the child widgets of each DropdownMenuItem.
List<String> _dropdownItemTexts(WidgetTester tester) {
  final dropdown = tester.widget<FormBuilderDropdown<String>>(
    find.byType(FormBuilderDropdown<String>),
  );
  return dropdown.items
      .map((item) {
        final textWidget = item.child as Text;
        return textWidget.data ?? '';
      })
      .toList();
}

Future<void> _pump(
  WidgetTester tester,
  SelectField field,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          child: field,
        ),
      ),
    ),
  );
}

void main() {
  group('SelectField option translation', () {
    testWidgets('options are translated when translate is set', (tester) async {
      final translations = {'Yes': 'हाँ', 'No': 'नहीं', 'Maybe': 'शायद'};
      final field = SelectField(
        field: _field(),
        style: _styleWithTranslate((s) => translations[s] ?? s),
      );

      await _pump(tester, field);

      final labels = _dropdownItemTexts(tester);
      expect(labels, containsAll(['हाँ', 'नहीं', 'शायद']));
      // Original English strings must NOT appear as display labels
      expect(labels, isNot(contains('Yes')));
      expect(labels, isNot(contains('No')));
      expect(labels, isNot(contains('Maybe')));
    });

    testWidgets('options are unchanged when translate is null', (tester) async {
      final field = SelectField(field: _field());

      await _pump(tester, field);

      final labels = _dropdownItemTexts(tester);
      expect(labels, containsAll(['Yes', 'No', 'Maybe']));
    });

    testWidgets('DropdownMenuItem values remain English keys even with translation',
        (tester) async {
      final translations = {'Yes': 'हाँ', 'No': 'नहीं', 'Maybe': 'शायद'};
      final field = SelectField(
        field: _field(),
        style: _styleWithTranslate((s) => translations[s] ?? s),
      );

      await _pump(tester, field);

      final dropdown = tester.widget<FormBuilderDropdown<String>>(
        find.byType(FormBuilderDropdown<String>),
      );
      // The stored value (item.value) must remain the English key
      final values = dropdown.items.map((item) => item.value).toList();
      expect(values, containsAll(['Yes', 'No', 'Maybe']));
      expect(values, isNot(contains('हाँ')));
      expect(values, isNot(contains('नहीं')));
      expect(values, isNot(contains('शायद')));
    });

    testWidgets('stored value (English key) is unaffected by translation',
        (tester) async {
      String? submittedValue;
      final field = SelectField(
        field: _field(options: 'Yes\nNo'),
        value: 'Yes',
        onChanged: (v) => submittedValue = v?.toString(),
        style: _styleWithTranslate(
            (s) => s == 'Yes' ? 'हाँ' : s == 'No' ? 'नहीं' : s),
      );

      await _pump(tester, field);
      expect(submittedValue, isNull); // no change triggered yet
    });

    testWidgets(
        'single-option auto-select fires with English key, not translated label',
        (tester) async {
      String? autoSelectedValue;
      final field = SelectField(
        field: _field(options: 'Yes'),
        onChanged: (v) => autoSelectedValue = v?.toString(),
        style: _styleWithTranslate((s) => s == 'Yes' ? 'हाँ' : s),
      );

      await _pump(tester, field);
      // Allow the post-frame callback to run
      await tester.pump();

      expect(autoSelectedValue, equals('Yes'),
          reason:
              'Auto-select must store the English key, not the translated label');
    });
  });
}
