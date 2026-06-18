import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_helpers.dart';

void main() {
  group('requiredValidator', () {
    test('null value returns error', () {
      expect(requiredValidator(null, 'Field'), isNotNull);
    });

    test('empty string returns error', () {
      expect(requiredValidator('', 'Field'), isNotNull);
    });

    test('non-empty string returns null (valid)', () {
      expect(requiredValidator('hello', 'Field'), isNull);
    });

    // Regression: [].toString() == "[]" — not empty — so the old
    // value.toString().isEmpty check incorrectly passed an empty list.
    test('empty List returns error (multi-select unselected)', () {
      expect(
        requiredValidator(<String>[], 'Symptoms'),
        isNotNull,
        reason: '[].toString() == "[]" — must not be treated as non-empty',
      );
    });

    test('non-empty List returns null (multi-select has selection)', () {
      expect(requiredValidator(['Fever'], 'Symptoms'), isNull);
    });

    test('empty Iterable returns error', () {
      expect(
        requiredValidator(const Iterable<String>.empty(), 'Field'),
        isNotNull,
      );
    });
  });
}
