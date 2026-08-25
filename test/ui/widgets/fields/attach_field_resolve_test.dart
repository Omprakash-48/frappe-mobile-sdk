import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';

/// The widget depends on the [ResolveMediaFn] function, not on [MediaResolver],
/// so these tests need no database and no filesystem. That matters: widget
/// tests run in a fake-async zone where real sqflite / dart:io futures never
/// complete, so `pumpAndSettle` would hang forever on the real resolver.
/// MediaResolver's own behaviour is covered in test/services/media_resolver_test.dart.
void main() {
  final docField = DocField(
    fieldname: 'doc',
    fieldtype: 'Attach',
    label: 'Document',
  );

  late List<String> resolveCalls;

  setUp(() => resolveCalls = <String>[]);

  ResolveMediaFn resolverReturning(String? path) {
    return (String value, {Map<int, String>? pendingPaths}) async {
      resolveCalls.add(value);
      if (path == null) return null;
      // Mirror the real resolver: a marker resolves through the staging map.
      if (value.startsWith('pending:')) {
        final id = int.tryParse(value.substring('pending:'.length));
        return id == null ? null : pendingPaths?[id];
      }
      return path;
    };
  }

  Future<GlobalKey<FormBuilderState>> pump(
    WidgetTester tester, {
    dynamic value,
    ResolveMediaFn? mediaResolver,
    Map<int, String>? pendingAttachmentPaths,
  }) async {
    final key = GlobalKey<FormBuilderState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            key: key,
            child: AttachField(
              field: docField,
              value: value,
              mediaResolver: mediaResolver,
              pendingAttachmentPaths: pendingAttachmentPaths,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('a pending marker labels from its staged file', (tester) async {
    await pump(
      tester,
      value: 'pending:7',
      mediaResolver: resolverReturning('/cache/whatever.pdf'),
      pendingAttachmentPaths: {7: '/outbox/staged.pdf'},
    );
    expect(find.text('staged.pdf'), findsOneWidget);
  });

  testWidgets('a cached file keeps the SERVER filename in the label, not the '
      'cache hash', (tester) async {
    // cachePathFor names files sha256(file_url); surfacing that would replace
    // "report.pdf" with 64 hex characters.
    await pump(
      tester,
      value: '/files/report.pdf',
      mediaResolver: resolverReturning('/cache/9f8e7d6c5b4a3f2e1d.pdf'),
    );
    expect(find.text('report.pdf'), findsOneWidget);
    expect(find.text('9f8e7d6c5b4a3f2e1d.pdf'), findsNothing);
  });

  testWidgets('the stored value is never mutated by display resolution', (
    tester,
  ) async {
    final key = await pump(
      tester,
      value: '/files/report.pdf',
      mediaResolver: resolverReturning('/cache/abc.pdf'),
    );
    expect(key.currentState?.fields['doc']?.value, '/files/report.pdf');
  });

  testWidgets('an unresolvable value still renders and keeps its value', (
    tester,
  ) async {
    final key = await pump(
      tester,
      value: '/files/absent.pdf',
      mediaResolver: resolverReturning(null),
    );
    expect(find.text('absent.pdf'), findsOneWidget);
    expect(key.currentState?.fields['doc']?.value, '/files/absent.pdf');
  });

  testWidgets('rendering the field does NOT resolve — no fetch before a tap', (
    tester,
  ) async {
    // Round-4 review H1. This used to assert the opposite: resolution ran from
    // `MediaResolveBuilder.initState`, and `MediaResolver.resolve` DOWNLOADS on
    // a cache miss. So opening a form pulled every attachment on it, up to
    // 25 MB each, before the user asked for any of them — on a device floor of
    // API 26 and often a metered rural connection. This widget renders only a
    // button, so there is no render-time need for the bytes at all.
    await pump(
      tester,
      value: '/files/report.pdf',
      mediaResolver: resolverReturning('/cache/abc.pdf'),
    );
    await tester.pump();
    await tester.pump();

    expect(
      resolveCalls,
      isEmpty,
      reason: 'a form with five attachments must not download five files',
    );
  });

  testWidgets('the resolver is invoked once per tap, not once per rebuild', (
    tester,
  ) async {
    // The original loop guard, still load-bearing: resolving inside `build`
    // creates a new future on every rebuild and each completion triggers
    // another rebuild — an infinite loop that can re-download forever. A tap
    // handler sidesteps it, so one tap must mean exactly one resolve.
    // An IMAGE value on purpose: a resolved non-image ends in
    // `OpenFilex.open`, which spawns a real platform process and leaves a
    // pending timer the fake-async test binding rejects. An image resolves
    // down the same path and then just pushes the full-screen viewer.
    await pump(
      tester,
      value: '/files/photo.jpg',
      mediaResolver: resolverReturning('/cache/abc.jpg'),
    );

    await tester.tap(find.byTooltip('View'));
    await tester.pump();
    await tester.pump();

    expect(resolveCalls, ['/files/photo.jpg']);
  });

  testWidgets('with no resolver the field still renders (host opt-in)', (
    tester,
  ) async {
    // Additive: hosts that never wire one keep the previous behaviour rather
    // than losing their preview.
    await pump(tester, value: '/uploads/report.pdf');
    expect(find.text('report.pdf'), findsOneWidget);
    expect(resolveCalls, isEmpty);
  });
}
