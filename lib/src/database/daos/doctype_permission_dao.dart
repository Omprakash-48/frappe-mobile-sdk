import 'package:sqflite/sqflite.dart';
import '../entities/doctype_permission_entity.dart';

class DoctypePermissionDao {
  final Database _database;

  DoctypePermissionDao(this._database);

  Future<DoctypePermissionEntity?> findByDoctype(String doctype) async {
    final maps = await _database.query(
      'doctype_permission',
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DoctypePermissionEntity.fromDb(maps.first);
  }

  Future<void> upsert(DoctypePermissionEntity entity) async {
    await _database.insert(
      'doctype_permission',
      entity.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertAll(List<DoctypePermissionEntity> entities) async {
    if (entities.isEmpty) return;
    final batch = _database.batch();
    for (final e in entities) {
      batch.insert(
        'doctype_permission',
        e.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Authoritatively replace the permission cache in one transaction from the
  /// full `mobile_auth.permissions` set. Doctypes in [entities] are inserted;
  /// doctypes cached before but ABSENT from [entities] are server-revoked and
  /// are written back as EXPLICIT all-false DENIAL rows rather than deleted.
  ///
  /// Why not just delete them: the read getters (`canRead`/`canWrite`/…)
  /// default an ABSENT row to `true` (allow). Deleting a revoked doctype would
  /// therefore silently RE-GRANT it — the opposite of an authoritative prune.
  /// An explicit all-false row denies it, while an absent row still means
  /// "never synced".
  ///
  /// No-ops on an empty list so a transient/empty server response can never
  /// wipe a good cache.
  Future<void> replaceAll(List<DoctypePermissionEntity> entities) async {
    if (entities.isEmpty) return;
    final incoming = {for (final e in entities) e.doctype};
    await _database.transaction((txn) async {
      final existing = await txn.query(
        'doctype_permission',
        columns: ['doctype'],
      );
      final revoked = <String>[
        for (final row in existing)
          if (!incoming.contains(row['doctype'] as String))
            row['doctype'] as String,
      ];
      await txn.delete('doctype_permission');
      final batch = txn.batch();
      for (final e in entities) {
        batch.insert(
          'doctype_permission',
          e.toDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      // Preserve revoked doctypes as explicit all-false denial rows so the read
      // getters deny them instead of defaulting an absent row to allow.
      for (final doctype in revoked) {
        batch.insert(
          'doctype_permission',
          DoctypePermissionEntity(doctype: doctype).toDb(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> deleteAll() async {
    await _database.delete('doctype_permission');
  }
}
