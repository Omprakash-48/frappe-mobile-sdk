// The five attachment capabilities — `isOnline`, `pendingAttachmentPaths`,
// `mediaResolver`, `isOfflineMode`, `imagePickSource` — used to be
// `createField` parameters, which broke every host subclass written against the
// published signature (Dart requires an override to redeclare every named
// parameter of the method it overrides). They are now `FieldFactory` instance
// state, assigned by `_configureFieldFactoryForMeta`.
//
// That move is only correct if the values still REACH the widgets, and every
// one of them fails silently when it does not: a null `mediaResolver` degrades
// to network-only, a null `isOfflineMode` uploads inline instead of queueing,
// an absent `pendingAttachmentPaths` renders no preview for a `pending:<id>`
// marker. No exception, no failing build — just the pre-offline behaviour back.
// So assert identity at the widget, for both modes, parent and child row.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/image_pick_source.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  DocTypeMeta parentMeta() => DocTypeMeta(
    name: 'Visit',
    fields: <DocField>[
      DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
      DocField(
        fieldname: 'lines',
        fieldtype: 'Table',
        label: 'Lines',
        options: 'VisitLine',
      ),
    ],
  );

  DocTypeMeta childMeta() => DocTypeMeta(
    name: 'VisitLine',
    fields: <DocField>[
      DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Doc'),
    ],
  );

  bool online() => true;
  bool offlineMode() => true;
  Future<String?> resolve(
    String value, {
    Map<int, String>? pendingPaths,
  }) async => null;
  ImagePickSource pickSource() => ImagePickSource.camera;
  final pending = <int, String>{7: '/outbox/7.jpg'};

  Future<void> pumpForm(
    WidgetTester tester,
    FormBuilderMode mode, {
    FieldFactory? customFactory,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: parentMeta(),
            mode: mode,
            getMeta: (_) async => childMeta(),
            customFieldFactory: customFactory,
            isOnline: online,
            pendingAttachmentPaths: pending,
            mediaResolver: resolve,
            isOfflineMode: offlineMode,
            imagePickSource: pickSource,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // Both modes build fields through DIFFERENT methods (`_buildFieldWidget` vs
  // `_buildReactiveField`) and each constructs its own nested
  // `FrappeFormBuilder` for a child row, so neither proves the other.
  for (final mode in FormBuilderMode.values) {
    testWidgets('$mode: all five reach the parent image field', (tester) async {
      await pumpForm(tester, mode);

      final f = tester.widget<ImageField>(find.byType(ImageField));
      expect(f.isOnline, same(online));
      expect(f.pendingAttachmentPaths, same(pending));
      expect(f.mediaResolver, same(resolve));
      expect(f.isOfflineMode, same(offlineMode));
      expect(f.imagePickSource, same(pickSource));
    });

    testWidgets('$mode: the four reach a child-row attach field', (
      tester,
    ) async {
      await pumpForm(tester, mode);

      // A second forwarding hop: the child row renders inside the add-row
      // sheet, through the nested FrappeFormBuilder the parent constructs.
      await tester.tap(find.text('Add Row'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final f = tester.widget<AttachField>(find.byType(AttachField));
      expect(f.isOnline, same(online));
      expect(f.pendingAttachmentPaths, same(pending));
      expect(f.mediaResolver, same(resolve));
      expect(f.isOfflineMode, same(offlineMode));
    });
  }

  testWidgets('a host-supplied FieldFactory is configured with all five', (
    tester,
  ) async {
    // `customFieldFactory` is the documented extension point. Because these are
    // instance state now, a host factory the form never reconfigures would
    // build fields with every capability null — the exact silent regression
    // this file exists to catch.
    final hostFactory = FieldFactory();
    expect(hostFactory.isOnline, isNull, reason: 'starts unset');
    expect(hostFactory.mediaResolver, isNull, reason: 'starts unset');

    await pumpForm(tester, FormBuilderMode.legacy, customFactory: hostFactory);

    expect(hostFactory.isOnline, same(online));
    expect(hostFactory.pendingAttachmentPaths, same(pending));
    expect(hostFactory.mediaResolver, same(resolve));
    expect(hostFactory.isOfflineMode, same(offlineMode));
    expect(hostFactory.imagePickSource, same(pickSource));

    final f = tester.widget<ImageField>(find.byType(ImageField));
    expect(f.mediaResolver, same(resolve));
    expect(f.imagePickSource, same(pickSource));
  });

  testWidgets(
    'a host factory\'s own values are not clobbered when unsupplied',
    (tester) async {
      // Review round 4 (M3). The configure pass used to assign all six
      // capabilities unconditionally, so a host that wired its OWN factory and
      // did not repeat the values as `FrappeFormBuilder` arguments had them
      // overwritten on every build — `reclaimAttachment` with
      // `MediaStore.discardValue`, which DELETES a staged file a queued
      // `pending_attachments` row still owns, and the other five with null
      // (network-only previews, inline upload instead of queueing). Silent in
      // every case: no error, no diff, the capability just leaves.
      Future<void> hostReclaim(String? v) async {}
      final hostFactory = FieldFactory()
        ..reclaimAttachment = hostReclaim
        ..mediaResolver = resolve
        ..isOnline = online
        ..isOfflineMode = offlineMode
        ..pendingAttachmentPaths = pending
        ..imagePickSource = pickSource;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: parentMeta(),
              getMeta: (_) async => childMeta(),
              customFieldFactory: hostFactory,
              // Deliberately passes NONE of the six.
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        hostFactory.reclaimAttachment,
        same(hostReclaim),
        reason: 'the destructive default must never overwrite a host hook',
      );
      expect(hostFactory.mediaResolver, same(resolve));
      expect(hostFactory.isOnline, same(online));
      expect(hostFactory.isOfflineMode, same(offlineMode));
      expect(hostFactory.pendingAttachmentPaths, same(pending));
      expect(hostFactory.imagePickSource, same(pickSource));

      // And the field actually built with them, not just the factory.
      final f = tester.widget<ImageField>(find.byType(ImageField));
      expect(f.reclaimAttachment, same(hostReclaim));
      expect(f.mediaResolver, same(resolve));
    },
  );

  testWidgets('a later pendingAttachmentPaths reaches the field on rebuild', (
    tester,
  ) async {
    // This is the one that is NOT stable per meta: it changes as picks
    // complete. `_configureFieldFactoryForMeta` runs from `build`, not only
    // from `initState`/`didUpdateWidget`, which is what covers it — a new map
    // arrives with no meta change at all.
    Widget formWith(Map<int, String> paths) => MaterialApp(
      home: Scaffold(
        body: FrappeFormBuilder(
          meta: parentMeta(),
          getMeta: (_) async => childMeta(),
          pendingAttachmentPaths: paths,
        ),
      ),
    );

    await tester.pumpWidget(formWith(pending));
    await tester.pump();
    expect(
      tester.widget<ImageField>(find.byType(ImageField)).pendingAttachmentPaths,
      same(pending),
    );

    final later = <int, String>{9: '/outbox/9.jpg'};
    await tester.pumpWidget(formWith(later));
    await tester.pump();
    expect(
      tester.widget<ImageField>(find.byType(ImageField)).pendingAttachmentPaths,
      same(later),
      reason: 'a pick completing after mount must still reach the field',
    );
  });
}
