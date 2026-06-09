import 'dart:async';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../database/daos/translation_dao.dart';

class TranslationService {
  final FrappeClient? _client;

  TranslationDao? _dao;

  /// In-memory cache: lang -> (source -> translated)
  final Map<String, Map<String, String>> _cache = {};

  /// Current locale for [translate]. Default "en".
  String _currentLang = 'en';

  final _changedController = StreamController<void>.broadcast();

  /// Emits after [loadFromCache] populates rows or [refreshAsync] completes.
  Stream<void> get onChanged => _changedController.stream;

  TranslationService(this._client);

  /// Use in tests only — creates service without HTTP client.
  @visibleForTesting
  factory TranslationService.forTesting() => TranslationService(null);

  /// Inject the persistence DAO. Called once by FrappeSDK after DB init.
  void injectDao(TranslationDao dao) => _dao = dao;

  /// Exposed only for unit tests to read the injected DAO.
  @visibleForTesting
  TranslationDao get dao => _dao!;

  /// Overrides currentLang in tests without touching the cache.
  @visibleForTesting
  void setCurrentLangForTesting(String lang) => _currentLang = lang;

  /// Current language code used for [translate].
  String get currentLang => _currentLang;

  /// Load translations for [lang] from SQLite into [_cache].
  /// Fast (<5 ms). No network. Emits [onChanged] if rows were found.
  Future<void> loadFromCache(String lang) async {
    if (_dao == null) return;
    try {
      final map = await _dao!.readAll(lang);
      if (map.isEmpty) return;
      _cache[lang] = map;
      _changedController.add(null);
    } catch (e, st) {
      debugPrint('TranslationService.loadFromCache($lang) failed — $e\n$st');
    }
  }

  /// Fire-and-forget: fetch from API → persist to SQLite → update cache → emit [onChanged].
  /// Errors are swallowed; the existing in-memory or SQLite cache remains valid.
  void refreshAsync(String lang) {
    unawaited(_doRefresh(lang));
  }

  Future<void> _doRefresh(String lang) async {
    final map = await loadTranslations(lang); // fetches + populates _cache[lang]
    if (map.isEmpty) return;
    try {
      await _dao?.bulkUpsert(lang, map);
    } catch (e, st) {
      debugPrint('TranslationService._doRefresh($lang) persist failed — $e\n$st');
    }
    _changedController.add(null);
  }

  /// Set the active language. Loads from SQLite cache first (instant),
  /// then starts a background API refresh to keep the cache fresh.
  Future<void> setLocale(String lang) async {
    if (lang.isEmpty) return;
    _currentLang = lang;
    if (!_cache.containsKey(lang)) {
      await loadFromCache(lang);
    }
    refreshAsync(lang);
  }

  /// Fetch translations for [lang] from API and populate [_cache].
  /// Response format: { "data": { "translations": { "hi": { "source": "target" } } } }
  Future<Map<String, String>> loadTranslations(String lang) async {
    try {
      final result = await _client?.rest.get(
        '/api/v2/method/mobile_auth.get_translations',
        queryParams: {'lang': lang},
      );
      if (result is! Map<String, dynamic>) return {};
      final data = result['data'] as Map<String, dynamic>? ?? result;
      final translationsMap = data['translations'] as Map<String, dynamic>?;
      if (translationsMap == null) return {};
      final raw = translationsMap[lang] as Map<String, dynamic>?;
      if (raw == null) return {};
      final map = raw.map(
        (k, v) => MapEntry(k.toString(), v?.toString() ?? k.toString()),
      );
      _cache[lang] = map;
      return map;
    } catch (e, st) {
      debugPrint('TranslationService.loadTranslations($lang) failed — $e\n$st');
      return {};
    }
  }

  /// Get cached translations for [lang]. Empty if not loaded.
  Map<String, String> getCachedTranslations(String lang) =>
      Map.from(_cache[lang] ?? {});

  /// Translate [source] using the current language cache.
  /// Supports {0}, {1}, ... positional argument substitution.
  /// Returns [source] unchanged if no translation is found.
  String translate(String source, [List<Object>? args]) {
    if (source.isEmpty) return source;
    final map = _cache[_currentLang];
    String text = (map != null ? map[source] : null) ?? source;
    if (args != null && args.isNotEmpty) {
      for (var i = 0; i < args.length; i++) {
        text = text.replaceAll('{$i}', args[i].toString());
      }
    }
    return text;
  }

  /// Alias for [translate] (Frappe-style `__`).
  String call(String source, [List<Object>? args]) => translate(source, args);

  /// Closes the SQLite cache and the change stream.
  /// Called by [FrappeSDK.dispose].
  Future<void> dispose() async {
    await _dao?.close();
    await _changedController.close();
  }
}
