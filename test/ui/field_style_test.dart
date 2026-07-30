import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';

void main() {
  // B6 (PR#36 round-4): the defaults were silently changed true→false, so any
  // consumer constructing FieldStyle(...) for an unrelated reason (e.g. a
  // custom decoration) lost all labels/descriptions. FrappeFormBuilder always
  // passes these explicitly, so the default only affects external consumers —
  // restore the backward-compatible true default.
  test('FieldStyle defaults showLabel and showDescription to true', () {
    const s = FieldStyle();
    expect(s.showLabel, isTrue);
    expect(s.showDescription, isTrue);
  });
}
