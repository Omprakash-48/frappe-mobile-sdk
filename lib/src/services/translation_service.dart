import 'dart:async';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../database/daos/translation_dao.dart';
import '../utils/sdk_log.dart';

class TranslationService {
  final FrappeClient? _client;

  TranslationDao? _dao;

  /// True once [dispose] has been called. Guards fire-and-forget paths
  /// (_doRefresh, _doRefreshAll, loadFromCache) so they bail out cleanly
  /// when the DAO/stream have already been closed.
  bool _disposed = false;

  /// Incremented by [clearAll] (logout). In-flight [loadTranslations] and
  /// [_doRefresh] calls snapshot this value before their first await and
  /// compare after each suspension point — if the snapshot no longer matches,
  /// clearAll() fired while they were awaiting and they discard their results
  /// instead of repopulating the freshly-wiped cache and SQLite table.
  int _clearGeneration = 0;

  /// Optional external delegate to intercept/override translations (e.g. static host app ARB strings).
  String Function(String source, [List<Object>? args])? translateDelegate;

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
    if (_dao == null || _disposed) return;
    try {
      final map = await _dao!.readAll(lang);
      if (map.isEmpty) return;
      _cache[lang] = map;
      if (!_changedController.isClosed) _changedController.add(null);
    } catch (e, st) {
      sdkLog('TranslationService.loadFromCache($lang) failed — $e\n$st');
    }
  }

  /// Fire-and-forget: fetch from API → persist to SQLite → update cache → emit [onChanged].
  /// Errors are swallowed; the existing in-memory or SQLite cache remains valid.
  void refreshAsync(String lang) {
    unawaited(_doRefresh(lang));
  }

  Future<void> _doRefresh(String lang) async {
    final gen = _clearGeneration; // snapshot before any await
    final map = await loadTranslations(lang); // fetches + populates _cache[lang]
    // Guard: dispose OR clearAll() may have fired while we were awaiting.
    if (_disposed || _clearGeneration != gen) return;
    if (map.isEmpty) return;
    try {
      await _dao?.bulkUpsert(lang, map);
    } catch (e, st) {
      sdkLog('TranslationService._doRefresh($lang) persist failed — $e\n$st');
      // fall through — in-memory cache is valid even if SQLite persistence
      // failed; notify listeners so the UI reflects the updated cache.
    }
    if (!_changedController.isClosed) _changedController.add(null);
  }

  /// Awaitable: fetch ALL enabled languages from Frappe and persist each.
  /// Called (awaited) inside the post-login meta sync so the SQLite cache is
  /// fully populated before the "Syncing…" indicator clears.  Errors per
  /// language are swallowed individually; a failing language never aborts the
  /// rest of the batch.
  Future<void> refreshAll() => _doRefreshAll();

  /// Fire-and-forget alias for callers that cannot or do not need to await.
  void refreshAllAsync() {
    unawaited(_doRefreshAll());
  }

  Future<void> _doRefreshAll() async {
    if (_disposed) return;
    final langs = await fetchEnabledLanguages();
    // Serial by design: awaiting each language fetch prevents concurrent
    // requests from hammering the Frappe server and triggering rate limits.
    // This is a necessary trade-off given the current single-language API.
    // TODO(translations): replace serial loop with a paginated bulk-fetch
    // endpoint once the translations API supports it — avoids N round-trips.
    for (final lang in langs) {
      if (_disposed) return;
      await _doRefresh(lang);
    }
  }

  /// Fetches the list of enabled language codes via frappe.client.get_list on
  /// the Language doctype. Used by [refreshAllAsync] to know which languages
  /// to pre-warm into SQLite after login.
  Future<List<String>> fetchEnabledLanguages() async {
    try {
      final result = await _client?.rest.get(
        '/api/v2/method/frappe.client.get_list',
        queryParams: {
          'doctype': 'Language',
          'fields': '["name"]',
          'filters': '[["enabled","=","1"]]',
          'limit_page_length': '0',
        },
      );
      if (result is! Map<String, dynamic>) return [];
      final data = result['data'];
      if (data is! List) return [];
      return data
          .cast<Map<String, dynamic>>()
          .map((e) => e['name']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (e, st) {
      sdkLog('TranslationService.fetchEnabledLanguages failed — $e\n$st');
      return [];
    }
  }

  /// Set the active language. Reads SQLite cache only — **no network call**.
  ///
  /// Safe to call before login (app startup, locale restore) without triggering
  /// a 403.  Callers that want a background network refresh after confirming an
  /// active session should call [refreshAsync] or [refreshAll] separately.
  ///
  /// The SQLite reload is unconditional — no [_cache.containsKey] guard — so
  /// a locale switch always picks up the latest persisted translations even if
  /// [_cache] already holds a stale or empty entry for [lang].
  Future<void> setLocale(String lang) async {
    if (lang.isEmpty) return;
    _currentLang = lang;
    await loadFromCache(lang);
  }

  /// Fetch translations for [lang] from the Frappe mobile-auth whitelist API.
  /// This endpoint merges compiled (.po) translations with custom Translation
  /// doctype entries — the complete set needed to translate field labels offline.
  ///
  /// [frappe.client.get_list('Translation')] is NOT used here because it only
  /// returns user-created custom translations; compiled .po field-label
  /// translations are not stored in the Translation doctype.
  ///
  /// Response format:
  ///   { "data": { "translations": { "hi": { "Source": "Translated" } } } }
  Future<Map<String, String>> loadTranslations(String lang) async {
    if (_disposed) return {};
    final gen = _clearGeneration; // snapshot before any await
    try {
      final result = await _client?.rest.get(
        '/api/v2/method/mobile_auth.get_translations',
        queryParams: {'lang': lang},
      );
      // If clearAll() fired while we were awaiting the HTTP response, discard
      // the result — writing stale data back into the freshly-wiped cache
      // would re-populate it as if logout had never happened.
      if (_clearGeneration != gen) return {};
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
      sdkLog('TranslationService.loadTranslations($lang) failed — $e\n$st');
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
    if (translateDelegate != null) {
      final ext = translateDelegate!(source, args);
      if (ext != source) {
        return ext;
      }
    }
    return translateLocal(source, args);
  }

  /// Looks up translation locally in SQLite cache / in-memory cache.
  String translateLocal(String source, [List<Object>? args]) {
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

  /// Clears in-memory cache, resets currentLang to 'en', and wipes the
  /// SQLite translation cache. Called on logout.
  ///
  /// Bumps [_clearGeneration] first so any in-flight [loadTranslations] or
  /// [_doRefresh] calls detect the logout and discard their results instead
  /// of repopulating the freshly-wiped cache.
  Future<void> clearAll() async {
    _clearGeneration++; // must come before _cache.clear() so in-flight paths see it
    _cache.clear();
    _currentLang = 'en';
    try {
      await _dao?.deleteAll();
    } catch (e, st) {
      sdkLog('TranslationService.clearAll: deleteAll failed — $e\n$st');
    }
  }

  /// Closes the SQLite cache and the change stream.
  /// Called by [FrappeSDK.dispose].
  Future<void> dispose() async {
    _disposed = true; // guard first — before closing
    await _dao?.close();
    await _changedController.close();
  }
}
