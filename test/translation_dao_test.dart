import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/translation_dao.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<TranslationDao> makeDao() => TranslationDao.forTesting();

  group('bulkUpsert + readAll', () {
    test('upserts and reads rows for a single lang', () async {
      final dao = await makeDao();
      await dao.bulkUpsert('hi', {'Hello': 'नमस्ते', 'Yes': 'हाँ'});
      final result = await dao.readAll('hi');
      expect(result, {'Hello': 'नमस्ते', 'Yes': 'हाँ'});
      await dao.close();
    });

    test('readAll returns empty map for unknown lang', () async {
      final dao = await makeDao();
      final result = await dao.readAll('fr');
      expect(result, isEmpty);
      await dao.close();
    });

    test('upsert replaces existing rows', () async {
      final dao = await makeDao();
      await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await dao.bulkUpsert('hi', {'Yes': 'जी हाँ'});
      final result = await dao.readAll('hi');
      expect(result['Yes'], 'जी हाँ');
      await dao.close();
    });

    test('bulkUpsert is a no-op for empty map', () async {
      final dao = await makeDao();
      await dao.bulkUpsert('hi', {});
      expect(await dao.readAll('hi'), isEmpty);
      await dao.close();
    });

    test('upserts and reads rows for multiple langs', () async {
      final dao = await makeDao();
      await dao.bulkUpsert('hi', {'Hello': 'नमस्ते'});
      await dao.bulkUpsert('mr', {'Hello': 'नमस्कार'});
      expect((await dao.readAll('hi'))['Hello'], 'नमस्ते');
      expect((await dao.readAll('mr'))['Hello'], 'नमस्कार');
      await dao.close();
    });
  });

  group('deleteAll', () {
    test('removes all rows across all langs', () async {
      final dao = await makeDao();
      await dao.bulkUpsert('hi', {'Hello': 'नमस्ते', 'Yes': 'हाँ'});
      await dao.bulkUpsert('mr', {'Hello': 'नमस्कार'});

      await dao.deleteAll();

      expect(await dao.readAll('hi'), isEmpty);
      expect(await dao.readAll('mr'), isEmpty);
      await dao.close();
    });

    test('deleteAll on empty table does not throw', () async {
      final dao = await makeDao();
      await expectLater(dao.deleteAll(), completes);
      await dao.close();
    });

    test('re-insert after deleteAll works', () async {
      final dao = await makeDao();
      await dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await dao.deleteAll();
      await dao.bulkUpsert('hi', {'No': 'नहीं'});
      final result = await dao.readAll('hi');
      expect(result, {'No': 'नहीं'});
      expect(result.containsKey('Yes'), isFalse);
      await dao.close();
    });
  });

  group('close', () {
    test(
      'forTesting() DAO owns its handle: close() frees it (BS2 — no leak)',
      () async {
        final dao = await makeDao();
        await dao.bulkUpsert('hi', {'A': 'B'});
        await dao.close();
        // The in-memory connection this DAO opened is genuinely released —
        // a subsequent query throws rather than silently leaking the handle.
        expect(dao.readAll('hi'), throwsA(isA<DatabaseException>()));
      },
    );
  });
}
