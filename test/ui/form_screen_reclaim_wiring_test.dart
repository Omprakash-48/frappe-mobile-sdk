// The last hop. FormScreen is the SDK's own host, so if it does not hand its
// repository's queue-aware reclaim to the form, every attach field inside it
// falls back to `MediaStore.discardValue` — which deletes a staged file a
// committed `pending_attachments` row still owns. The fix is inert without
// this line, and nothing else in the tree would notice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  fields: [
    DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
  });

  tearDown(() async => appDb.close());

  testWidgets('FormScreen hands the form its repository queue-aware reclaim', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormScreen(meta: _meta(), repository: repo),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<FrappeFormBuilder>(find.byType(FrappeFormBuilder))
          .reclaimAttachment,
      equals(repo.reclaimDiscardedAttachment),
      reason: 'the default MediaStore.discardValue cannot see the queue',
    );
  });
}
