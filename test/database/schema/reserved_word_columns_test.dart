// Regression tests: DDL emitted by `buildChildSchemaDDL` /
// `buildParentSchemaDDL` must quote column identifiers so meta fields
// whose `fieldname` collides with a SQL reserved word (`create`,
// `delete`, `cancel`, etc.) don't produce a SQLite syntax error.
//
// Concrete trigger in the field: Frappe's core `User Document Type`
// (istable=1) has fields literally named `create`, `delete`, `cancel`,
// `submit`. Before the fix, `buildChildSchemaDDL` emitted
// `... , create INTEGER, ...` which SQLite rejects with
// `near "create": syntax error`. That throw escaped
// `OfflineRepository.ensureSchemaForClosure`'s loop and aborted the
// entire migration on first login, leaving every queued-after child
// table unbuilt.

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String name, String type) =>
    DocField(fieldname: name, fieldtype: type, label: name);

// Real Frappe `User Document Type` field shape (frappe/core/doctype/
// user_document_type/user_document_type.json).
final _userDocumentTypeFields = <DocField>[
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
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('buildChildSchemaDDL with reserved-word fieldnames', () {
    test('quotes column identifiers in CREATE TABLE', () {
      final meta = DocTypeMeta(
        name: 'User Document Type',
        isTable: true,
        fields: _userDocumentTypeFields,
      );
      final ddl = buildChildSchemaDDL(
        meta,
        tableName: 'docs__user_document_type',
      );
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      // The bare token `create INTEGER` is what SQLite rejects. Quoted
      // identifiers are accepted.
      expect(
        createStmt,
        contains('"create" INTEGER'),
        reason: 'reserved-word column "create" must be quoted',
      );
      expect(
        createStmt,
        contains('"delete" INTEGER'),
        reason: 'reserved-word column "delete" must be quoted',
      );
      expect(
        createStmt,
        contains('"cancel" INTEGER'),
        reason: 'reserved-word column "cancel" must be quoted',
      );
    });

    test('emitted DDL is accepted by SQLite (parses + executes)', () async {
      final meta = DocTypeMeta(
        name: 'User Document Type',
        isTable: true,
        fields: _userDocumentTypeFields,
      );
      final ddl = buildChildSchemaDDL(
        meta,
        tableName: 'docs__user_document_type',
      );
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      try {
        for (final stmt in ddl) {
          await db.execute(stmt);
        }
        // Sanity: each reserved-word column made it into the table.
        final cols = await db.rawQuery(
          'PRAGMA table_info(docs__user_document_type)',
        );
        final names = cols.map((r) => r['name'] as String).toSet();
        for (final reserved in const [
          'create',
          'delete',
          'cancel',
          'submit',
          'read',
          'write',
        ]) {
          expect(
            names,
            contains(reserved),
            reason: 'column "$reserved" must be present',
          );
        }
      } finally {
        await db.close();
      }
    });
  });

  group('buildParentSchemaDDL with reserved-word fieldnames', () {
    test('quotes column identifiers in CREATE TABLE', () {
      // Hypothetical: a parent doctype that exposes a `create` flag field.
      // Same quoting rule must hold.
      final meta = DocTypeMeta(
        name: 'Permission Profile',
        fields: [
          f('profile_name', 'Data'),
          f('create', 'Check'),
          f('delete', 'Check'),
        ],
      );
      final ddl = buildParentSchemaDDL(
        meta,
        tableName: 'docs__permission_profile',
      );
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('"create" INTEGER'));
      expect(createStmt, contains('"delete" INTEGER'));
    });

    test('emitted DDL is accepted by SQLite (parses + executes)', () async {
      final meta = DocTypeMeta(
        name: 'Permission Profile',
        fields: [
          f('profile_name', 'Data'),
          f('create', 'Check'),
          f('delete', 'Check'),
        ],
      );
      final ddl = buildParentSchemaDDL(
        meta,
        tableName: 'docs__permission_profile',
      );
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      try {
        for (final stmt in ddl) {
          await db.execute(stmt);
        }
        final cols = await db.rawQuery(
          'PRAGMA table_info(docs__permission_profile)',
        );
        final names = cols.map((r) => r['name'] as String).toSet();
        expect(names, contains('create'));
        expect(names, contains('delete'));
      } finally {
        await db.close();
      }
    });
  });
}
