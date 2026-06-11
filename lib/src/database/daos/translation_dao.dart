import 'package:sqflite/sqflite.dart';

/// A standalone KV SQLite cache for translation strings.
///
/// Uses the injected [Database] from [AppDatabase].
class TranslationDao {
  static const _tableName = 'kv';

  final Database _db;

  TranslationDao(this._db);

  /// Use in tests only — opens an in-memory database so no filesystem I/O
  /// occurs and each [TranslationDao.forTesting()] instance is isolated.
  static Future<TranslationDao> forTesting() async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      singleInstance: false,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_tableName (
            lang TEXT NOT NULL,
            src  TEXT NOT NULL,
            tgt  TEXT NOT NULL,
            PRIMARY KEY (lang, src)
          )
        ''');
      },
    );
    return TranslationDao(db);
  }

  /// Inserts or replaces all entries in [map] for [lang].
  ///
  /// Uses a batched transaction for efficiency. Handles arbitrarily large maps
  /// by writing all rows inside a single transaction batch.
  Future<void> bulkUpsert(String lang, Map<String, String> map) async {
    if (map.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final e in map.entries) {
        batch.insert(_tableName, {
          'lang': lang,
          'src': e.key,
          'tgt': e.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  /// Returns all cached translations for [lang] as a source → target map.
  ///
  /// Returns an empty map if [lang] has no cached entries.
  Future<Map<String, String>> readAll(String lang) async {
    final rows = await _db.query(
      _tableName,
      columns: ['src', 'tgt'],
      where: 'lang = ?',
      whereArgs: [lang],
    );
    return {for (final r in rows) r['src'] as String: r['tgt'] as String};
  }

  /// Deletes ALL rows from the kv table. Called by [TranslationService.clearAll]
  /// on logout to wipe the translation cache for all languages.
  Future<void> deleteAll() async {
    await _db.delete(_tableName);
  }

  /// Closes the underlying database connection.
  Future<void> close() async {
    // Let AppDatabase manage connection lifecycle; do nothing here.
  }
}
