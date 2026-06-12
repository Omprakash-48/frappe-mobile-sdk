import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/daos/translation_dao.dart';
import 'package:frappe_mobile_sdk/src/services/translation_service.dart';

/// Build a MockClient that serves the mobile_auth.get_translations response.
/// The [langToTranslations] map is keyed by language code; each value is a
/// map of source → translated.  The mock inspects the ?lang= query param and
/// returns only the matching language block.
http.Client _scripted(
  Map<String, Map<String, dynamic>> langToTranslations, {
  List<Map<String, dynamic>>? sentSink,
  http.Response? overrideAll,
}) {
  return MockClient((req) async {
    sentSink?.add({'method': req.method, 'url': req.url.toString()});
    if (overrideAll != null) return overrideAll;

    final requestedLang = req.url.queryParameters['lang'];

    final translations = requestedLang != null
        ? (langToTranslations[requestedLang] ?? <String, dynamic>{})
        : <String, dynamic>{};

    // mobile_auth.get_translations response shape:
    // { "data": { "translations": { "<lang>": { "Source": "Target" } } } }
    final body = {
      'data': {
        'translations': {
          if (requestedLang != null) requestedLang: translations,
        },
      },
    };
    return http.Response(jsonEncode(body), 200);
  });
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('default currentLang is "en"', () {
    final svc = TranslationService(FrappeClient('http://localhost'));
    expect(svc.currentLang, 'en');
  });

  test('translate returns source when no cache exists', () {
    final svc = TranslationService(FrappeClient('http://localhost'));
    expect(svc.translate('Hello'), 'Hello');
  });

  test('translate returns empty when source is empty', () {
    final svc = TranslationService(FrappeClient('http://localhost'));
    expect(svc.translate(''), '');
  });

  test(
    'loadTranslations parses {data.translations.<lang>} and caches',
    () async {
      final client = FrappeClient(
        'http://localhost',
        httpClient: _scripted({
          'hr': {'Hello': 'Bok', 'Bye': 'Bye-hr'},
        }),
      );
      final svc = TranslationService(client);
      final map = await svc.loadTranslations('hr');
      expect(map, {'Hello': 'Bok', 'Bye': 'Bye-hr'});
      // Cached:
      expect(svc.getCachedTranslations('hr'), {
        'Hello': 'Bok',
        'Bye': 'Bye-hr',
      });
    },
  );

  test('loadTranslations returns empty map when lang not in payload', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'hr': {'Hello': 'Bok'},
      }),
    );
    final svc = TranslationService(client);
    // Requesting 'xx' — not present in the scripted map; server returns {}
    // for that lang block, so the parser returns an empty map.
    final map = await svc.loadTranslations('xx');
    expect(map, isEmpty);
  });

  test(
    'loadTranslations returns empty map on non-map server response',
    () async {
      final client = FrappeClient(
        'http://localhost',
        httpClient: MockClient(
          (_) async => http.Response('"unexpected-string"', 200),
        ),
      );
      final svc = TranslationService(client);
      final map = await svc.loadTranslations('hr');
      expect(map, isEmpty);
    },
  );

  test('loadTranslations swallows server errors and returns empty', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: MockClient((_) async => http.Response('boom', 500)),
    );
    final svc = TranslationService(client);
    final map = await svc.loadTranslations('hr');
    expect(map, isEmpty);
  });

  test(
    'setLocale sets currentLang and does NOT make a network call',
    () async {
      // setLocale is SQLite-only — callers that want a network refresh must
      // call refreshAsync / refreshAll separately (after confirming a session
      // is active).  This test asserts that no HTTP request is fired.
      final calls = <Map<String, dynamic>>[];
      final client = FrappeClient(
        'http://localhost',
        httpClient: _scripted({
          'my': {'Yes': 'Yes-my'},
        }, sentSink: calls),
      );
      final svc = TranslationService(client);
      await svc.setLocale('my');
      await Future<void>.delayed(Duration.zero); // drain microtasks
      expect(svc.currentLang, 'my');
      expect(calls, isEmpty, reason: 'setLocale must not fire any HTTP request');
    },
  );

  test(
    'refreshAsync fires a network request and caches the result',
    () async {
      final calls = <Map<String, dynamic>>[];
      final client = FrappeClient(
        'http://localhost',
        httpClient: _scripted({
          'my': {'Yes': 'Yes-my'},
        }, sentSink: calls),
      );
      final svc = TranslationService(client);
      await svc.setLocale('my');
      final loaded = svc.onChanged.first;
      svc.refreshAsync('my');
      await loaded.timeout(const Duration(seconds: 2));
      expect(calls, hasLength(1));
      expect(calls.first['url'], contains('get_translations'));
      expect(svc.translate('Yes'), 'Yes-my');
    },
  );

  test('setLocale ignores empty string', () async {
    final svc = TranslationService(FrappeClient('http://localhost'));
    await svc.setLocale('');
    expect(svc.currentLang, 'en');
  });

  test('translate after loadTranslations uses cached translation', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'Hello': 'Howdy'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    expect(svc.translate('Hello'), 'Howdy');
    expect(
      svc.translate('Unknown'),
      'Unknown',
      reason: 'missing keys fall back to the source string',
    );
  });

  test('translate substitutes positional placeholders', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'Welcome {0}, age {1}': 'Hi {0}, you are {1}'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    expect(
      svc.translate('Welcome {0}, age {1}', ['Ada', 36]),
      'Hi Ada, you are 36',
    );
  });

  test('call() is an alias for translate', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'Hello': 'Howdy'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    expect(svc('Hello'), 'Howdy');
  });

  test('getCachedTranslations returns a defensive copy', () async {
    final client = FrappeClient(
      'http://localhost',
      httpClient: _scripted({
        'en': {'A': '1'},
      }),
    );
    final svc = TranslationService(client);
    await svc.loadTranslations('en');
    final snapshot = svc.getCachedTranslations('en');
    snapshot['A'] = 'mutated';
    expect(
      svc.translate('A'),
      '1',
      reason: 'caller mutation must not leak into cache',
    );
  });

  // Regression: clearAll() must prevent an in-flight refreshAsync from
  // repopulating the wiped in-memory cache and SQLite kv table.
  // The generation counter (_clearGeneration) bumped in clearAll() causes
  // the in-flight _doRefresh / loadTranslations to bail before writing.
  //
  // Note on assertions:
  //   clearAll() resets _currentLang to 'en', so translate() would look up
  //   _cache['en'], not _cache['hi'].  We check getCachedTranslations('hi')
  //   directly to verify the cache for the fetched language was NOT written.
  test(
    'clearAll generation: in-flight refresh does NOT repopulate cache after clearAll',
    () async {
      // A Completer lets us hold the HTTP response until we choose to release it.
      final fetchCompleter = Completer<http.Response>();
      final mockClient = MockClient((_) => fetchCompleter.future);
      final svc = TranslationService(
        FrappeClient('http://localhost', httpClient: mockClient),
      );

      // Inject an in-memory DAO so we can verify SQLite is not repopulated.
      final db = await databaseFactory.openDatabase(
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
      svc.injectDao(TranslationDao(db));

      // Start a background refresh — HTTP fetch is now blocked.
      svc.refreshAsync('hi');

      // While the fetch is in-flight, logout clears the service.
      await svc.clearAll();

      // Unblock the fetch with valid translation data.
      // Use Response.bytes so the Devanagari string survives the Latin-1 check.
      fetchCompleter.complete(http.Response.bytes(
        utf8.encode(jsonEncode({
          'data': {
            'translations': {
              'hi': {'Hello': 'नमस्ते'},
            },
          },
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      ));

      // Give the entire async chain time to complete: MockClient → FrappeClient
      // response parsing → loadTranslations cache write → _doRefresh bulkUpsert.
      // Without the generation guard, all these writes will have landed by now.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // In-memory cache for 'hi' must remain empty after clearAll.
      expect(
        svc.getCachedTranslations('hi'),
        isEmpty,
        reason:
            'cleared cache[hi] must not be repopulated by in-flight request after logout',
      );

      // SQLite kv table must also be empty.
      final rows = await db.query('kv');
      expect(rows, isEmpty,
          reason: 'kv table must not be repopulated after clearAll');

      await db.close();
    },
  );
}
