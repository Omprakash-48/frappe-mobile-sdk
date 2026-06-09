import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/translation_dao.dart';
import 'package:frappe_mobile_sdk/src/services/translation_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  TranslationService _service() =>
      TranslationService.forTesting()..injectDao(TranslationDao.forTesting());

  group('loadFromCache', () {
    test('populates _cache from DAO', () async {
      final svc = _service();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ', 'No': 'नहीं'});
      await svc.loadFromCache('hi');
      expect(svc.translate('Yes'), 'Yes'); // currentLang is 'en', not 'hi' yet
      svc.setCurrentLangForTesting('hi');
      expect(svc.translate('Yes'), 'हाँ');
      expect(svc.translate('No'), 'नहीं');
      await svc.dao.close();
    });

    test('no-op when DAO has no rows for lang', () async {
      final svc = _service();
      await svc.loadFromCache('hi');
      svc.setCurrentLangForTesting('hi');
      expect(svc.translate('Yes'), 'Yes'); // falls back to source
      await svc.dao.close();
    });
  });

  group('translate fallback', () {
    test('returns source key when no translation found', () {
      final svc = TranslationService.forTesting();
      expect(svc.translate('Unknown Key'), 'Unknown Key');
    });

    test('returns empty string for empty source', () {
      final svc = TranslationService.forTesting();
      expect(svc.translate(''), '');
    });
  });

  group('onChanged stream', () {
    test('emits after loadFromCache when rows present', () async {
      final svc = _service();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      final events = <void>[];
      svc.onChanged.listen((_) => events.add(null));
      await svc.loadFromCache('hi');
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      await svc.dao.close();
    });

    test('does not emit after loadFromCache when DAO is empty', () async {
      final svc = _service();
      final events = <void>[];
      svc.onChanged.listen((_) => events.add(null));
      await svc.loadFromCache('hi');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await svc.dao.close();
    });
  });

  group('setLocale', () {
    test('updates currentLang immediately', () async {
      final svc = _service();
      await svc.setLocale('hi');
      expect(svc.currentLang, 'hi');
      await Future<void>.delayed(Duration.zero); // drain background refreshAsync
      await svc.dao.close();
    });

    test('loads from cache when DB has rows', () async {
      final svc = _service();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await svc.setLocale('hi');
      expect(svc.translate('Yes'), 'हाँ');
      await Future<void>.delayed(Duration.zero); // drain background refreshAsync
      await svc.dao.close();
    });
  });

  group('dispose safety', () {
    test('no StateError when dispose is called before onChanged emits', () async {
      final svc = _service();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});

      final errors = <Object>[];
      await runZonedGuarded(
        () async {
          // loadFromCache awaits the DAO, then emits onChanged — the guard
          // must prevent a StateError if the controller is already closed.
          await svc.loadFromCache('hi');
          await svc.dispose(); // closes the StreamController
          // Give the event loop a turn; no emission should follow dispose.
          await Future<void>.delayed(const Duration(milliseconds: 10));
        },
        (e, _) => errors.add(e),
      );

      expect(errors, isEmpty,
          reason: 'No StateError or other error should be thrown after dispose');
    });

    test('onChanged stream is closed after dispose and emits no further events',
        () async {
      final svc = _service();
      await svc.dao.bulkUpsert('hi', {'Yes': 'हाँ'});
      await svc.loadFromCache('hi'); // prime the cache + first emission
      await svc.dispose();

      var extraEvents = 0;
      // Listening to a closed broadcast stream is harmless but receives nothing.
      svc.onChanged.listen((_) => extraEvents++);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(extraEvents, 0);
    });
  });
}
