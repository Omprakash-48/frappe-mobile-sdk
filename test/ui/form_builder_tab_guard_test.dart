import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds a DocTypeMeta with [tabCount] Tab Break / Data field pairs.
/// All metas share the same [name] so the name-only guard does NOT fire.
DocTypeMeta _tabMeta(String name, int tabCount) => DocTypeMeta(
      name: name,
      fields: [
        for (var i = 0; i < tabCount; i++) ...[
          DocField(fieldname: 'tab_$i', fieldtype: 'Tab Break', label: 'Tab ${i + 1}'),
          DocField(fieldname: 'field_$i', fieldtype: 'Data', label: 'Field ${i + 1}'),
        ],
      ],
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
    'didUpdateWidget rebuilds TabController when tab count changes with same doctype name',
    (WidgetTester tester) async {
      // Start with 2 tabs.
      DocTypeMeta currentMeta = _tabMeta('SameDoc', 2);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    ElevatedButton(
                      key: const ValueKey('swap_meta'),
                      onPressed: () => setState(() {
                        // Swap to 3 tabs — same doctype name, structural change.
                        currentMeta = _tabMeta('SameDoc', 3);
                      }),
                      child: const Text('Swap'),
                    ),
                    Expanded(
                      child: FrappeFormBuilder(meta: currentMeta),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(2));

      // Swap meta: same name, one extra tab.  Without the tab-count guard in
      // didUpdateWidget, the stale TabController(length: 2) stays alive while
      // the rebuilt TabBar tries to render 3 tabs — Flutter asserts
      // "tabs.length == controller.length" and the test fails with a FlutterError.
      await tester.tap(find.byKey(const ValueKey('swap_meta')));
      await tester.pumpAndSettle();

      // After fix: TabController is rebuilt for 3 tabs; no assertion error.
      expect(find.byType(Tab), findsNWidgets(3));
    },
  );
}
