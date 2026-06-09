import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// A standalone KV SQLite cache for translation strings.
///
/// Opens its own `translations_cache.db` file — completely independent of the
/// main [AppDatabase]. This is intentional: it is a pure cache that can be
/// wiped freely and requires no migrations.
class TranslationDao {
  static const _tableName = 'kv';

  final String _dbPath;
  Database? _db;

  TranslationDao() : _dbPath = 'translations_cache.db';

  /// Use in tests only — opens an in-memory database so no filesystem I/O
  /// occurs and each [TranslationDao.forTesting()] instance is isolated.
  TranslationDao.forTesting() : _dbPath = inMemoryDatabasePath;

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final path = _dbPath == inMemoryDatabasePath
        ? _dbPath
        : join(await getDatabasesPath(), _dbPath);
    _db = await openDatabase(
      path,
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
    return _db!;
  }

  /// Inserts or replaces all entries in [map] for [lang].
  ///
  /// Uses a batched transaction for efficiency. Handles arbitrarily large maps
  /// by writing all rows inside a single transaction batch.
  Future<void> bulkUpsert(String lang, Map<String, String> map) async {
    if (map.isEmpty) return;
    final db = await _open();
    await db.transaction((txn) async {
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
    final db = await _open();
    final rows = await db.query(
      _tableName,
      columns: ['src', 'tgt'],
      where: 'lang = ?',
      whereArgs: [lang],
    );
    return {for (final r in rows) r['src'] as String: r['tgt'] as String};
  }

  /// Closes the underlying database connection.
  ///
  /// After calling this, any subsequent operation will re-open the database.
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
