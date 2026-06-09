import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/translation_dao.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('TranslationDao', () {
    test('readAll returns empty map for unknown lang', () async {
      final dao = TranslationDao.forTesting();
      expect(await dao.readAll('hi'), isEmpty);
      await dao.close();
    });

    test('bulkUpsert then readAll round-trips all entries', () async {
      final dao = TranslationDao.forTesting();
      await dao.bulkUpsert('hi', {'Yes': 'हाँ', 'No': 'नहीं', 'Father': 'पिता'});
      final result = await dao.readAll('hi');
      expect(result, {'Yes': 'हाँ', 'No': 'नहीं', 'Father': 'पिता'});
      await dao.close();
    });

    test('two languages do not bleed into each other', () async {
      final dao = TranslationDao.forTesting();
      await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await dao.bulkUpsert('gu', {'Yes': 'હા'});
      expect(await dao.readAll('hi'), {'Yes': 'हाँ'});
      expect(await dao.readAll('gu'), {'Yes': 'હા'});
      await dao.close();
    });

    test('bulkUpsert overwrites existing keys for same lang', () async {
      final dao = TranslationDao.forTesting();
      await dao.bulkUpsert('hi', {'Yes': 'old'});
      await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      expect((await dao.readAll('hi'))['Yes'], 'हाँ');
      await dao.close();
    });

    test('bulkUpsert with empty map is a no-op', () async {
      final dao = TranslationDao.forTesting();
      await dao.bulkUpsert('hi', {});
      expect(await dao.readAll('hi'), isEmpty);
      await dao.close();
    });

    test('bulkUpsert handles 900 entries without error', () async {
      final dao = TranslationDao.forTesting();
      final large = {for (var i = 0; i < 900; i++) 'key_$i': 'val_$i'};
      await dao.bulkUpsert('hi', large);
      final result = await dao.readAll('hi');
      expect(result.length, 900);
      await dao.close();
    });
  });
}
