import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// `getLinkTitle` — single Link VALUE (`name`) → display title, offline-first,
/// cached. This is the resolution DocumentListScreen uses so DF list rows can
/// show "Deepak" instead of a raw uuid/EP id (bug #121).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late UnifiedResolver resolver;
  late DocTypeMeta m;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');
    for (final s in doctypeMetaExtensionsDDL()) {
      await db.execute(s);
    }
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    m = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data'), f('age', 'Int')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': jsonEncode(m.toJson()),
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer_name': 'ACME',
      'customer_name__norm': 'acme',
      'age': 10,
    });
    resolver = UnifiedResolver(
      db: db,
      metaDao: DoctypeMetaDao(db),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: (dt) async => m,
    );
  });

  tearDown(() async => db.close());

  LinkOptionService makeSvc() => LinkOptionService(resolver, (dt) async => m);

  group('getLinkTitle', () {
    test('resolves a link value to the target doctype title', () async {
      final title = await makeSvc().getLinkTitle('Customer', 'CUST-1');
      expect(title, 'ACME');
    });

    test('returns null for an unknown value', () async {
      final title = await makeSvc().getLinkTitle('Customer', 'NOPE-404');
      expect(title, isNull);
    });

    test('returns null for an empty value', () async {
      final title = await makeSvc().getLinkTitle('Customer', '');
      expect(title, isNull);
    });

    test('caches per (doctype, name) — repeated calls stay correct', () async {
      final svc = makeSvc();
      expect(await svc.getLinkTitle('Customer', 'CUST-1'), 'ACME');
      // Second call is served from cache (no DB dependency): delete the row
      // and the cached title must still come back.
      await db.delete('docs__customer');
      expect(await svc.getLinkTitle('Customer', 'CUST-1'), 'ACME');
    });
  });
}
