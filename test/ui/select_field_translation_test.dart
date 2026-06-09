import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';

FieldStyle _styleWithTranslate(String Function(String) t) =>
    FieldStyle(translate: t);

DocField _field({
  String options = 'Yes\nNo\nMaybe',
  bool allowMultiple = false,
}) => DocField(
  fieldname: 'test_field',
  fieldtype: 'Select',
  label: 'Test',
  options: options,
  allowMultiple: allowMultiple,
);

/// Extracts display text from the child widgets of each DropdownMenuItem.
List<String> _dropdownItemTexts(WidgetTester tester) {
  final dropdown = tester.widget<FormBuilderDropdown<String>>(
    find.byType(FormBuilderDropdown<String>),
  );
  return dropdown.items.map((item) {
    final textWidget = item.child as Text;
    return textWidget.data ?? '';
  }).toList();
}

Future<void> _pump(WidgetTester tester, SelectField field) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: FormBuilder(child: field)),
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

    testWidgets(
      'DropdownMenuItem values remain English keys even with translation',
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
      },
    );

    testWidgets('stored value (English key) is unaffected by translation', (
      tester,
    ) async {
      final translations = {'Yes': 'हाँ', 'No': 'नहीं'};
      final field = SelectField(
        field: _field(options: 'Yes\nNo'),
        value: 'Yes',
        style: _styleWithTranslate((s) => translations[s] ?? s),
      );

      await _pump(tester, field);

      // The dropdown renders without error and translated labels appear in the items.
      expect(find.byType(FormBuilderDropdown<String>), findsOneWidget);

      // Translated label must appear as the display text in the dropdown items.
      final labels = _dropdownItemTexts(tester);
      expect(labels, containsAll(['हाँ', 'नहीं']));
      expect(labels, isNot(contains('Yes')));
      expect(labels, isNot(contains('No')));

      // The item values (stored keys) must remain the English originals.
      final dropdown = tester.widget<FormBuilderDropdown<String>>(
        find.byType(FormBuilderDropdown<String>),
      );
      final values = dropdown.items.map((item) => item.value).toList();
      expect(values, containsAll(['Yes', 'No']));
      expect(values, isNot(contains('हाँ')));
      expect(values, isNot(contains('नहीं')));
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

        expect(
          autoSelectedValue,
          equals('Yes'),
          reason:
              'Auto-select must store the English key, not the translated label',
        );
      },
    );

    // ── Multi-select (allowMultiple: true) ──────────────────────────────────

    testWidgets('multi-select options are translated in display labels', (
      tester,
    ) async {
      final translations = {'Yes': 'हाँ', 'No': 'नहीं'};
      final field = SelectField(
        field: _field(options: 'Yes\nNo', allowMultiple: true),
        style: _styleWithTranslate((s) => translations[s] ?? s),
      );

      await _pump(tester, field);

      // FormBuilderCheckboxGroup renders each option's child Text widget.
      expect(find.text('हाँ'), findsOneWidget);
      expect(find.text('नहीं'), findsOneWidget);
      expect(find.text('Yes'), findsNothing);
      expect(find.text('No'), findsNothing);
    });

    testWidgets('multi-select stored values remain English keys after tap', (
      tester,
    ) async {
      final List<String> captured = [];
      final field = SelectField(
        field: _field(options: 'Yes\nNo', allowMultiple: true),
        onChanged: (v) {
          if (v is String && v.isNotEmpty) {
            captured.addAll(v.split(',').map((e) => e.trim()));
          }
        },
        style: _styleWithTranslate(
          (s) => s == 'Yes'
              ? 'हाँ'
              : s == 'No'
              ? 'नहीं'
              : s,
        ),
      );

      await _pump(tester, field);

      // Tap the translated label for "Yes" — should record the English key.
      await tester.tap(find.text('हाँ'));
      await tester.pump();

      expect(
        captured,
        contains('Yes'),
        reason: 'Stored value must be the English key, not a translated label',
      );
      expect(
        captured,
        isNot(contains('हाँ')),
        reason: 'Translated label must never be stored as a value',
      );
      expect(captured, isNot(contains('नहीं')));
    });

    testWidgets('multi-select single-option auto-select emits English key', (
      tester,
    ) async {
      String? emitted;
      final field = SelectField(
        field: _field(options: 'Only', allowMultiple: true),
        onChanged: (v) => emitted = v?.toString(),
        style: _styleWithTranslate((s) => 'अकेला'),
      );

      await _pump(tester, field);
      // Allow the post-frame callback to fire.
      await tester.pump();

      if (emitted != null) {
        expect(
          emitted,
          equals('Only'),
          reason:
              'Auto-select must emit the English key, not the translated label',
        );
        expect(emitted, isNot(equals('अकेला')));
      }
    });
  });
}
