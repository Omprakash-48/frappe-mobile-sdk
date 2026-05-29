// End-to-end regression: a malformed CREATE for one doctype in the
// closure must not silently abort the rest of the migration.
//
// Concrete trigger: Frappe core `User Document Type` (istable=1) has
// fields `create` / `delete` / `cancel`. The DDL builder used to emit
// `... , create INTEGER, ...` unquoted, which SQLite rejects. The
// throw escaped the `for (final entry in metas.entries)` loop in
// `OfflineRepository.ensureSchemaForClosure` (only the outer call
// site caught it, in frappe_sdk.dart), so every doctype iterated
// AFTER the failing one ended up without an offline table.
//
// Two independent defects are exercised here:
//   1. Identifier quoting in the schema DDL builders.
//   2. Per-iteration try/catch in the closure loop so any single
//      malformed CREATE can't kill the rest of the migration.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/sqlite_utils.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String name, String type, {String? options}) =>
    DocField(fieldname: name, fieldtype: type, label: name, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(appDb);
  });

  tearDown(() async {
    await appDb.rawDatabase.close();
  });

  test(
    'doctypes iterated AFTER a reserved-word child still get their tables',
    () async {
      // Real shape of Frappe core `User Document Type`. With the
      // pre-fix builder this CREATE blows up SQLite parsing.
      final userDocumentType = DocTypeMeta(
        name: 'User Document Type',
        isTable: true,
        fields: [
          f('document_type', 'Link'),
          f('is_custom', 'Check'),
          f('read', 'Check'),
          f('write', 'Check'),
          f('create', 'Check'),
          f('submit', 'Check'),
          f('cancel', 'Check'),
          f('amend', 'Check'),
          f('delete', 'Check'),
          f('email', 'Check'),
          f('share', 'Check'),
          f('print', 'Check'),
        ],
      );
      // Innocent doctypes that come AFTER `User Document Type` in
      // `metas.entries` iteration order. Pre-fix, these never get
      // tables because the loop aborts on the prior throw.
      final member = DocTypeMeta(
        name: 'Member',
        fields: [
          f('member_name', 'Data'),
          f('items', 'Table', options: 'Member Document Item'),
        ],
      );
      final memberDocumentItem = DocTypeMeta(
        name: 'Member Document Item',
        isTable: true,
        fields: [f('document_name', 'Data')],
      );

      for (final m in [userDocumentType, member, memberDocumentItem]) {
        await appDb.doctypeMetaDao.upsertMetaJson(
          m.name,
          jsonEncode(m.toJson()),
        );
      }

      // LinkedHashMap insertion order = iteration order. Reserved-word
      // doctype is iterated FIRST so any "abort on throw" bug strands
      // the later doctypes.
      final metas = <String, DocTypeMeta>{
        'User Document Type': userDocumentType,
        'Member': member,
        'Member Document Item': memberDocumentItem,
      };

      await repo.ensureSchemaForClosure(
        metas: metas,
        childDoctypes: {'User Document Type', 'Member Document Item'},
      );

      // The downstream doctypes MUST have their offline tables — this
      // is the regression that was breaking Member push sync with
      // `no such column: parent_uuid`.
      expect(
        await sqliteTableExists(appDb.rawDatabase, 'docs__member'),
        isTrue,
        reason: 'parent table for Member must exist',
      );
      expect(
        await sqliteTableExists(
          appDb.rawDatabase,
          'docs__member_document_item',
        ),
        isTrue,
        reason: 'child table for Member Document Item must exist',
      );

      // And the User Document Type table itself should be present —
      // i.e. the DDL builder now emits valid SQL for reserved-word
      // columns.
      expect(
        await sqliteTableExists(appDb.rawDatabase, 'docs__user_document_type'),
        isTrue,
        reason: 'reserved-word child table must be created (quoted DDL)',
      );
    },
  );
}
