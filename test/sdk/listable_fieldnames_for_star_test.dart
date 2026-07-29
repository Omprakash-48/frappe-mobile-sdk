import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  group('listableFieldnamesForStar', () {
    test('excludes Image (no DB column) and layout/child fieldtypes', () {
      final meta = DocTypeMeta(
        name: 'X',
        fields: [
          f('customer_name', 'Data'),
          f('photo', 'Image'),
          f('sec', 'Section Break'),
          f('items', 'Table'),
          f('tags', 'Table MultiSelect'),
          f('logo', 'Image'),
        ],
      );
      final cols = listableFieldnamesForStar(meta);

      // Real data column kept.
      expect(cols, contains('customer_name'));
      // Image fieldnames must NOT be emitted — they have no get_list column.
      expect(cols, isNot(contains('photo')));
      expect(cols, isNot(contains('logo')));
      // Layout + child fieldtypes stay excluded.
      expect(cols, isNot(contains('sec')));
      expect(cols, isNot(contains('items')));
      expect(cols, isNot(contains('tags')));
      // Standard document columns are always present.
      expect(
        cols,
        containsAll(<String>[
          'name',
          'owner',
          'creation',
          'modified',
          'docstatus',
        ]),
      );
    });
  });
}
