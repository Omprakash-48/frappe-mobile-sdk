# Translations

This document describes how `frappe_mobile_sdk` handles translations: how strings inside the SDK are translated, how the host application hooks in its own compiled ARB strings, and how locale changes propagate reactively across the entire UI.

---

## Architecture

The translation pipeline has two complementary layers:

```
SDK screens / fields / validators
         │
         ▼  sdkTr('Save')
  FrappeTranslations.translate(source)           ← static registry (lib/src/utils/translate.dart)
         │
         ▼  delegates to
  TranslationService.translate(source)           ← owned by FrappeSDK
         │
         ├─► translateDelegate(source)           ← ARB lookup injected by host app
         │       if result != source → return it (ARB wins)
         │
         └─► translateLocal(source)              ← SQLite cache fallback
                 _cache[currentLang][source] ?? source
```

**Priority order (highest to lowest):**
1. Host app ARB lookup (compiled, type-safe, always current)
2. SQLite translation cache (`kv` table inside `AppDatabase`, populated from `mobile_auth.get_translations` after login)
3. Source string as-is (English fallback, never null)

---

## SDK-side: the `sdkTr` helper

Every user-visible string in SDK screens, fields, and validators calls the top-level `sdkTr` function (renamed from `tr` in commit `0dfe1e1` to avoid naming collisions with `easy_localization`/GetX in host apps):

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// Within an SDK widget build method:
Text(sdkTr('Save'))
Text(sdkTr('{0} records found', [count]))
```

`sdkTr` is exported from `frappe_mobile_sdk.dart` and resolves via `FrappeTranslations`, a thin static registry:

```dart
// lib/src/utils/translate.dart (SDK)
class FrappeTranslations {
  static void setDelegate(TranslateFn delegate) { ... }
  static String translate(String source, [List<Object>? args]) { ... }
}

String sdkTr(String source, [List<Object>? args]) =>
    FrappeTranslations.translate(source, args);
```

Until the host app wires a delegate, `sdkTr` performs simple positional `{0}` / `{1}` substitution and returns the source string unchanged — no crashes, no null returns.

**Host apps that previously imported `tr` from the SDK barrel** should define their own wrapper instead of importing `sdkTr`:

```dart
// lib/core/sdk/translation_provider.dart (host app)
String tr(String source, [List<Object>? args]) =>
    FrappeTranslations.translate(source, args);
```

This avoids renaming hundreds of call sites and decouples the host app from the SDK's internal naming.

---

## Translation API

Translations are fetched via the Frappe mobile-auth whitelist method:

```
GET /api/v2/method/mobile_auth.get_translations?lang=hi
```

Response format:
```json
{
  "data": {
    "translations": {
      "hi": {
        "Save": "सहेजें",
        "Child Name": "बच्चे का नाम",
        "Date of Birth": "जन्म तिथि"
      }
    }
  }
}
```

**Why not `frappe.client.get_list('Translation')`?** That endpoint only returns rows from the `Translation` doctype (user-created custom translations). The compiled `.po` translations that ship with Frappe and custom apps — which are the source of doctype field labels like "Child Name" — are NOT stored in that doctype. `mobile_auth.get_translations` merges both sources and is the only endpoint that returns the complete translation set needed to translate field labels offline.

Enabled languages are discovered via:
```
GET /api/v2/method/frappe.client.get_list
    ?doctype=Language
    &fields=["name"]
    &filters=[["enabled","=","1"]]
    &limit_page_length=0
```

---

## Host app integration

### 1. Wire the delegate (Riverpod)

In the `translationListenerProvider` (called once from inside `sdkInit.when(data:...)` in `ChetnaApp`):

```dart
// lib/core/sdk/translation_provider.dart
final translationListenerProvider = Provider<void>((ref) {
  final sdk = ref.watch(sdkProvider);

  // Wire global sdkTr() helper to the initialized TranslationService
  FrappeTranslations.setDelegate(sdk.translations.translate);

  // Inject ARB lookup: host app strings take priority over SQLite cache
  sdk.translations.translateDelegate = (String source, [List<Object>? args]) {
    return _currentLocalizations?.lookup(source, args) ?? source;
  };

  // Forward SDK change events to the Riverpod tick
  final sub = sdk.translations.onChanged.listen((_) {
    ref.read(translationTickProvider.notifier).state++;
  });
  ref.onDispose(sub.cancel);

  // React to locale switches
  ref.listen<Locale>(appLocaleProvider, (prev, next) {
    AppLocalizations.delegate.load(next).then((loc) {
      _currentLocalizations = loc;
      sdk.translations.setLocale(next.languageCode).then((_) {
        ref.read(translationTickProvider.notifier).state++;
      });
    });
  }, fireImmediately: true);
});
```

### 2. The ARB lookup extension

Flutter's generated `AppLocalizations` exposes only named getters (`l10n.save`, `l10n.login`). To look up by a string key at runtime, the project generates a switch-case extension:

```bash
dart run tools/generate_l10n_lookup.dart
```

This scans `lib/l10n/app_en.arb` and emits `lib/l10n/app_localizations_lookup.dart` with a `lookup(String key, ...)` extension on `AppLocalizations`. Re-run whenever you add or rename ARB keys.

### 3. Adding SDK strings to ARB

Every string called via `sdkTr(...)` in the SDK that should be translated must have an entry in `app_en.arb` (and its `app_hi.arb` / `app_gu.arb` counterparts):

```json
{
  "saveLabel": "Save",
  "@saveLabel": { "description": "Form save button label" }
}
```

The ARB key must match the switch-case in the generated lookup. Keys are camelCase ARB identifiers; the lookup extension maps English source strings to those identifiers.

---

## SQLite translation cache

`TranslationService` persists translations in the `kv` table inside `AppDatabase` (the main app database). `TranslationDao` is constructed with an injected `Database` handle; there is no separate `translations_cache.db` file. `TranslationDao.close()` is a no-op — `AppDatabase` owns the connection lifecycle. Clear via `TranslationService.clearAll()` or `AppDatabase.clearAllData()`.

| Source | What it covers | When loaded |
|--------|---------------|-------------|
| ARB files | Fixed UI strings (buttons, headers, validators) | Compile-time, instant |
| SQLite cache | Dynamic field labels, select options from Frappe doctype meta | Startup (<5 ms) + background refresh after login |

The `translate` method checks `translateDelegate` (ARB) first; if the result equals the source, it falls through to `translateLocal` (SQLite). This means:

- UI strings in ARB: always resolved correctly, even offline, even before API login.
- Doctype field labels that exist only in Frappe DB: resolved from SQLite cache on restart, refreshed from API in background.

---

## Locale lifecycle

```
app launch
  └─ sdkInitProvider
       ├─ sdk.initialize()
       └─ sdk.translations.setLocale(storedLang)   ← SharedPreferences 'user_locale'
            ├─ loadFromCache(lang)                  ← SQLite, <5 ms
            └─ refreshAsync(lang)                   ← background refresh for this language

login()
  └─ _translationService?.setLocale(lang)           ← language from login response
       ├─ loadFromCache(lang)
       └─ refreshAsync(lang)                        ← background refresh for user's language
  └─ _translationService?.refreshAllAsync()         ← NEW: pulls ALL enabled languages
       └─ fetchEnabledLanguages() → [hi, gu, ...]
            └─ for each lang: _doRefresh(lang)      ← fire-and-forget per language

ChetnaApp renders (sdkInit.when data:)
  └─ translationListenerProvider watched
       ├─ FrappeTranslations.setDelegate(sdk.translations.translate)
       ├─ sdk.translations.translateDelegate = ARB lookup
       ├─ sdk.translations.onChanged.listen → tick++
       └─ appLocaleProvider.listen (fireImmediately: true)
            └─ AppLocalizations.delegate.load(locale)
                 └─ _currentLocalizations = loc
                      └─ sdk.translations.setLocale(lang) → tick++

user changes locale in Settings
  └─ appLocaleProvider emits new Locale
       └─ (same path as above)

background refresh completes (~200 ms after login)
  └─ onChanged emits → tick++ → translationFnProvider invalidates → form rebuilds

logout()
  └─ _translationService?.clearAll()               ← NEW: clears SQLite + in-memory cache
       └─ TranslationDao.deleteAll()               ← wipes kv table in AppDatabase
```

**First-frame guarantee:** On every launch after the first, the SQLite cache is pre-warmed before the form screen mounts. The user's language is correct from frame 1 — no flash of English.

**Offline-first guarantee:** After the first successful login (while online), `refreshAllAsync` populates the cache for all enabled languages. Subsequent offline sessions have a fully populated SQLite cache regardless of which user logs in and which language they select.

**Session isolation:** `clearAll()` is called on logout, wiping the `kv` table inside `AppDatabase`. This prevents a different user (on a shared device) from seeing another user's cached translations on their next login.

---

## Reactive form integration

`DocumentFormScreen` uses `ref.watch(translationFnProvider)` instead of a direct tear-off:

```dart
// lib/features/documents/presentation/document_form_screen.dart
FormScreen(
  ...
  translate: ref.watch(translationFnProvider),
)
```

`translationFnProvider` returns a fresh anonymous closure `(String s) => sdk.translations.translate(s)` each time the tick increments. Because closures are never `==`-equal, Riverpod detects the change and `DocumentFormScreen` rebuilds with updated strings whenever:

- The SQLite cache is pre-warmed at startup
- The background API refresh completes
- The user switches language

---

## Dispose safety

`TranslationService` holds a `StreamController` and a `TranslationDao` handle. Both are closed in `dispose()`, which is called from `FrappeSDK.dispose()`. `refreshAllAsync` and `_doRefresh` are fire-and-forget — they can still be running when `dispose()` fires. Two guards prevent stale writes after disposal:

1. `_disposed` flag — checked at the start of `loadFromCache` and after every `await` in `_doRefresh`. Any code that runs after the flag is set returns immediately without writing.
2. `_changedController.isClosed` check — guards the `add(null)` call even if `_disposed` was briefly missed.

---

## Adding a new translatable string

**Fixed UI string (button, label, error message):**

1. Call `sdkTr('My string')` at the use site in the SDK widget.
2. Add to `lib/l10n/app_en.arb`:
   ```json
   "myStringKey": "My string",
   "@myStringKey": { "description": "Short description" }
   ```
3. Add translations to `app_hi.arb` and `app_gu.arb`.
4. Run `flutter gen-l10n` (host app).
5. Run `dart run tools/generate_l10n_lookup.dart` to regenerate the lookup extension.

**Dynamic field label (from Frappe doctype meta):**

No action needed — these flow through `TranslationService.translateLocal` via the SQLite cache, which is populated automatically from `mobile_auth.get_translations` after login. Ensure the string is translated in Frappe's `.po` files or the `Translation` doctype so the server returns it.

---

## Testing

SDK translation tests do not use the ARB pipeline (no host app in scope). They test `TranslationService` and `TranslationDao` directly:

```dart
// test/translation_service_test.dart
final svc = TranslationService.forTesting()..injectDao(TranslationDao.forTesting());
await svc.dao.bulkUpsert('hi', {'Save': 'सहेजें'});
await svc.loadFromCache('hi');
svc.setCurrentLangForTesting('hi');
expect(svc.translate('Save'), 'सहेजें');
```

Host-app integration tests (in the Chetna app's `test/` directory) mock `FrappeSDK` and verify that `translationListenerProvider` forwards `onChanged` events to `translationTickProvider`.

When writing SDK widget tests that involve translated strings, either:
- Pass a literal `translate` callback: `style: FieldStyle(translate: (s) => s)` — identity (no translation)
- Or use a fixture map: `style: FieldStyle(translate: (s) => {'Save': 'सहेजें'}[s] ?? s)`

---

## Why `sdkTr` and not `tr`

In host apps that use `easy_localization` or GetX, both packages export a top-level `tr()` function. Importing `frappe_mobile_sdk` alongside either package would produce an ambiguous-name compile error. `sdkTr` starts with a distinctive prefix that never conflicts with third-party localization helpers.

Host apps that want a short `tr(...)` call site should define their own wrapper (e.g. in `translation_provider.dart`) that delegates to `FrappeTranslations.translate`. This keeps call sites idiomatic and independent of the SDK's naming choices.
