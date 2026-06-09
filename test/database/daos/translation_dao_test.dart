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
      dao = TranslationDao.forTesting();
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
}
