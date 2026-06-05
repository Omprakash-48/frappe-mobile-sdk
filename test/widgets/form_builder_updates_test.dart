import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

class FormBuilderTestWrapper extends StatefulWidget {
  final DocTypeMeta meta;
  final Map<String, dynamic>? initialData;

  const FormBuilderTestWrapper({
    super.key,
    required this.meta,
    this.initialData,
  });

  @override
  State<FormBuilderTestWrapper> createState() => _FormBuilderTestWrapperState();
}

class _FormBuilderTestWrapperState extends State<FormBuilderTestWrapper> {
  late DocTypeMeta _meta;
  late Map<String, dynamic>? _initialData;

  @override
  void initState() {
    super.initState();
    _meta = widget.meta;
    _initialData = widget.initialData;
  }

  void updateForm({DocTypeMeta? meta, Map<String, dynamic>? initialData}) {
    setState(() {
      if (meta != null) _meta = meta;
      if (initialData != null) _initialData = initialData;
    });
  }

  @override
  Widget build(BuildContext context) {
    return FrappeFormBuilder(
      meta: _meta,
      initialData: _initialData,
    );
  }
}

void main() {
  testWidgets('BaseField wraps long label in Expanded and uses CrossAxisAlignment.start', (tester) async {
    final meta = DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(
          fieldname: 'name',
          fieldtype: 'Data',
          label: 'Very long field label that should wrap gracefully on multiple lines without throwing any RenderFlex overflow',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
          ),
        ),
      ),
    );

    // Verify label text is rendered
    expect(find.textContaining('Very long field label'), findsOneWidget);

    // Verify the Row containing the label text has CrossAxisAlignment.start
    final rowFinder = find.byWidgetPredicate((widget) => widget is Row && widget.crossAxisAlignment == CrossAxisAlignment.start);
    expect(rowFinder, findsOneWidget);

    // Verify that the label Text is wrapped inside an Expanded widget
    final expandedTextFinder = find.byWidgetPredicate((widget) =>
        widget is Expanded &&
        widget.child is Text &&
        (widget.child as Text).data != null &&
        (widget.child as Text).data!.contains('Very long field label'));
    expect(expandedTextFinder, findsOneWidget);
  });

  testWidgets('FrappeFormBuilder didUpdateWidget does not recreate TabController for content-equal maps', (tester) async {
    final meta = DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'name', fieldtype: 'Data', label: 'Name'),
      ],
    );

    final key = GlobalKey<_FormBuilderTestWrapperState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilderTestWrapper(
            key: key,
            meta: meta,
            initialData: const {'name': 'Alice', 'age': 30},
          ),
        ),
      ),
    );

    final dynamic state1 = tester.state(find.byType(FrappeFormBuilder));
    final tc1 = state1.tabController;
    expect(tc1, isNotNull);

    // Update with a different Map instance but containing identical content
    key.currentState!.updateForm(
      initialData: {'name': 'Alice', 'age': 30}, // new instance, same values
    );
    await tester.pump();

    final dynamic state2 = tester.state(find.byType(FrappeFormBuilder));
    final tc2 = state2.tabController;
    
    // The TabController instance should remain exactly the same
    expect(identical(tc1, tc2), isTrue);
  });

  testWidgets('FrappeFormBuilder didUpdateWidget recreates TabController when meta or data content changes without crashing', (tester) async {
    final meta1 = DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'name', fieldtype: 'Data', label: 'Name'),
      ],
    );

    final meta2 = DocTypeMeta(
      name: 'Vendor',
      fields: [
        DocField(fieldname: 'company', fieldtype: 'Data', label: 'Company'),
      ],
    );

    final key = GlobalKey<_FormBuilderTestWrapperState>();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilderTestWrapper(
            key: key,
            meta: meta1,
            initialData: const {'name': 'Alice'},
          ),
        ),
      ),
    );

    final dynamic state1 = tester.state(find.byType(FrappeFormBuilder));
    final tc1 = state1.tabController;
    expect(tc1, isNotNull);

    // Update the form contents (initialData changes)
    key.currentState!.updateForm(
      initialData: const {'name': 'Bob'},
    );
    await tester.pump();

    final dynamic state2 = tester.state(find.byType(FrappeFormBuilder));
    final tc2 = state2.tabController;
    
    // Ticker/TabController should be recreated (not identical)
    expect(identical(tc1, tc2), isFalse);

    // Update the form metadata (meta changes)
    key.currentState!.updateForm(
      meta: meta2,
    );
    await tester.pump();

    final dynamic state3 = tester.state(find.byType(FrappeFormBuilder));
    final tc3 = state3.tabController;
    
    // Ticker/TabController should be recreated again (not identical)
    expect(identical(tc2, tc3), isFalse);
  });
}
