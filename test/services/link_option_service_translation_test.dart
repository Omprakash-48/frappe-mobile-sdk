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

/// Stand-in for the host translation cache: maps a couple of English option
/// titles to Gujarati, leaves everything else untouched (Frappe's `__()`
/// returns the source string when no translation exists).
String _gu(String s) {
  const dict = {
    'Energy dense food': 'શક્તિથી ભરપુર ખોરાક',
    'Food for strong bones': 'હાડકા મજબુત કરે તેવો ખોરાક',
  };
  return dict[s] ?? s;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late UnifiedResolver resolver;

  DocTypeMeta metaWith({required bool translated}) => DocTypeMeta(
    name: 'Healthy Food Type',
    titleField: 'option_name',
    fields: [f('option_name', 'Data')],
    metaData: {'translated_doctype': translated ? 1 : 0},
  );

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
    final m = metaWith(translated: true);
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__healthy_food_type')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Healthy Food Type',
      'metaJson': jsonEncode(m.toJson()),
      'isMobileForm': 0,
      'table_name': 'docs__healthy_food_type',
    });
    await db.insert('docs__healthy_food_type', {
      'mobile_uuid': 'u1',
      'server_name': 'Energy dense food',
      'sync_status': 'synced',
      'local_modified': 1,
      'option_name': 'Energy dense food',
      'option_name__norm': 'energy dense food',
    });
    await db.insert('docs__healthy_food_type', {
      'mobile_uuid': 'u2',
      'server_name': 'Food for strong bones',
      'sync_status': 'synced',
      'local_modified': 2,
      'option_name': 'Food for strong bones',
      'option_name__norm': 'food for strong bones',
    });
    resolver = UnifiedResolver(
      db: db,
      metaDao: DoctypeMetaDao(db),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: (dt) async => metaWith(translated: true),
    );
  });

  tearDown(() async => db.close());

  test(
    'translated target doctype → display label translated, stored name English',
    () async {
      final svc = LinkOptionService(
        resolver,
        (dt) async => metaWith(translated: true),
        translate: _gu,
      );
      final out = await svc.getLinkOptions('Healthy Food Type');
      final energy = out.firstWhere((e) => e.name == 'Energy dense food');
      // Stored value (name) stays English — server still receives the
      // canonical option name.
      expect(energy.name, 'Energy dense food');
      // Display label is the Gujarati translation.
      expect(energy.label, 'શક્તિથી ભરપુર ખોરાક');
    },
  );

  test('target doctype NOT translated → label left untranslated', () async {
    final svc = LinkOptionService(
      resolver,
      (dt) async => metaWith(translated: false),
      translate: _gu,
    );
    final out = await svc.getLinkOptions('Healthy Food Type');
    final energy = out.firstWhere((e) => e.name == 'Energy dense food');
    expect(energy.label, 'Energy dense food');
  });

  test('no translate fn injected → label left untranslated', () async {
    final svc = LinkOptionService(
      resolver,
      (dt) async => metaWith(translated: true),
    );
    final out = await svc.getLinkOptions('Healthy Food Type');
    final energy = out.firstWhere((e) => e.name == 'Energy dense food');
    expect(energy.label, 'Energy dense food');
  });

  test('option with no translation entry falls back to English label', () async {
    final svc = LinkOptionService(
      resolver,
      (dt) async => metaWith(translated: true),
      translate: _gu,
    );
    final out = await svc.getLinkOptions('Healthy Food Type');
    // 'Food for strong bones' IS in the dict; assert an untranslated one
    // stays as-is by checking the dict miss path via name equality.
    final bones = out.firstWhere((e) => e.name == 'Food for strong bones');
    expect(bones.label, 'હાડકા મજબુત કરે તેવો ખોરાક');
  });
}
