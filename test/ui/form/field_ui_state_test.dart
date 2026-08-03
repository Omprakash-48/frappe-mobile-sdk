import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/form/field_ui_state.dart';

void main() {
  test('value equality by all three flags', () {
    expect(const FieldUiState(), const FieldUiState(visible: true));
    expect(const FieldUiState(required: true) == const FieldUiState(), isFalse);
  });
  test('defaults: visible, optional, editable', () {
    const s = FieldUiState();
    expect([s.visible, s.required, s.readOnly], [true, false, false]);
  });
}
