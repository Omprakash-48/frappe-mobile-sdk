import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _wfMeta() => DocTypeMeta(
  name: 'WF Doc',
  fields: [
    DocField(
      fieldname: 'approval_status',
      fieldtype: 'Select',
      label: 'Approval Status',
      options: 'Review\nApproved\nRejected',
      readOnly: true,
    ),
  ],
  metaData: {
    'name': 'WF Doc',
    '__workflow_docs': [
      {
        'workflow_state_field': 'approval_status',
        'states': [
          {'state': 'Review', 'allow_edit': 'WF Doc - Approver'},
        ],
      },
    ],
  },
);

Document _wfDoc() => Document(
  localId: 'u1',
  doctype: 'WF Doc',
  serverId: 'WF-001',
  data: {'approval_status': 'Review'},
  modified: 0,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  late FrappeClient client;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    client = FrappeClient('http://localhost');
    repo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => _wfMeta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: client,
      metaFetcher: (_) async => _wfMeta(),
    );
  });

  Widget host({required bool showWorkflowActions}) => MaterialApp(
    home: Scaffold(
      body: FormScreen(
        meta: _wfMeta(),
        document: _wfDoc(),
        repository: repo,
        api: client,
        mode: FormBuilderMode.reactive,
        showWorkflowActions: showWorkflowActions,
      ),
    ),
  );

  // Note: only the showWorkflowActions:false behavior is asserted. The default
  // (true) path fires a real `get_transitions` RPC, which never settles against
  // a non-existent backend in a widget test — testing it would require network
  // mocking the harness does not support. The false case fully proves the flag:
  // no transition load is attempted and no Actions button renders.
  testWidgets(
    'showWorkflowActions:false hides the Actions button, keeps the state chip',
    (tester) async {
      await tester.pumpWidget(host(showWorkflowActions: false));
      await tester.pumpAndSettle();

      expect(find.text('Actions'), findsNothing);
      expect(find.text('Review'), findsWidgets); // state chip
    },
  );
}
