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

  /// Full-replace the permission cache in a single transaction: clears every
  /// row then inserts [entities]. Use for an AUTHORITATIVE refresh (the full
  /// `mobile_auth.permissions` set) so doctypes revoked server-side are pruned.
  /// No-ops on an empty list so a transient/empty server response can never
  /// wipe a good cache.
  Future<void> replaceAll(List<DoctypePermissionEntity> entities) async {
    if (entities.isEmpty) return;
    await _database.transaction((txn) async {
      await txn.delete('doctype_permission');
      final batch = txn.batch();
      for (final e in entities) {
        batch.insert(
          'doctype_permission',
          e.toDb(),
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
