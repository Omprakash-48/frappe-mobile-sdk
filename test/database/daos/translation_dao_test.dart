import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/translation_dao.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('TranslationDao', () {
    late TranslationDao dao;

    setUp(() async {
      dao = await TranslationDao.forTesting();
    });

    tearDown(() async {
      await dao.close();
    });

    test('readAll returns empty map for unknown lang', () async {
      expect(await dao.readAll('hi'), isEmpty);
    });

    test('bulkUpsert then readAll round-trips all entries', () async {
      await dao.bulkUpsert('hi', {
        'Yes': 'हाँ',
        'No': 'नहीं',
        'Father': 'पिता',
      });
      final result = await dao.readAll('hi');
      expect(result, {'Yes': 'हाँ', 'No': 'नहीं', 'Father': 'पिता'});
    });

    test('two languages do not bleed into each other', () async {
      await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await dao.bulkUpsert('gu', {'Yes': 'હા'});
      expect(await dao.readAll('hi'), {'Yes': 'हाँ'});
      expect(await dao.readAll('gu'), {'Yes': 'હા'});
    });

    test('bulkUpsert overwrites existing keys for same lang', () async {
      await dao.bulkUpsert('hi', {'Yes': 'old'});
      await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      expect((await dao.readAll('hi'))['Yes'], 'हाँ');
    });

    test('bulkUpsert with empty map is a no-op', () async {
      await dao.bulkUpsert('hi', {});
      expect(await dao.readAll('hi'), isEmpty);
    });

    test('bulkUpsert handles 900 entries without error', () async {
      final large = {for (var i = 0; i < 900; i++) 'key_$i': 'val_$i'};
      await dao.bulkUpsert('hi', large);
      final result = await dao.readAll('hi');
      expect(result.length, 900);
    });
  });

  group('TranslationDao lifecycle (BS2)', () {
    test(
      'forTesting() owns its handle: close() actually frees the connection',
      () async {
        final dao = await TranslationDao.forTesting();
        await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
        await dao.close();
        // The connection is genuinely closed — a subsequent query throws
        // rather than silently leaking an open handle.
        expect(dao.readAll('hi'), throwsA(isA<DatabaseException>()));
      },
    );

    test(
      'production ctor does NOT own the shared handle: close() is a no-op',
      () async {
        // Mirror the production wiring: TranslationDao(sharedDb).
        final sharedDb = await databaseFactory.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            singleInstance: false,
            onCreate: (d, _) => d.execute(
              'CREATE TABLE kv (lang TEXT NOT NULL, src TEXT NOT NULL, '
              'tgt TEXT NOT NULL, PRIMARY KEY (lang, src))',
            ),
          ),
        );
        final dao = TranslationDao(sharedDb);
        await dao.close();
        // The shared handle must remain usable — close() must not tear down a
        // connection AppDatabase still owns.
        expect(await sharedDb.rawQuery('SELECT 1'), isNotEmpty);
        await sharedDb.close();
      },
    );
  });
}
