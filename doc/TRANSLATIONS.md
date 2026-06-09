# Translations

This document describes how `frappe_mobile_sdk` handles translations: how strings inside the SDK are translated, how the host application hooks in its own compiled ARB strings, and how locale changes propagate reactively across the entire UI.

---

## Architecture

The translation pipeline has two complementary layers:

```
SDK screens / fields / validators
         │
         ▼  tr('Save')
  FrappeTranslations.translate(source)           ← global helper (lib/src/utils/translate.dart)
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
2. SQLite translation cache (`translations_cache.db`, populated from `mobile_auth.get_translations`)
3. Source string as-is (English fallback, never null)

---

## SDK-side: the `tr` helper

Every user-visible string in SDK screens, fields, and validators calls the top-level `tr` function:

```dart
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

// In a widget build method:
Text(tr('Save'))
Text(tr('{0} records found', [count]))
```

`tr` is exported from `frappe_mobile_sdk.dart` and resolves via `FrappeTranslations`, a thin static registry:

```dart
// lib/src/utils/translate.dart (SDK)
class FrappeTranslations {
  static void setDelegate(TranslateFn delegate) { ... }
  static String translate(String source, [List<Object>? args]) { ... }
}

String tr(String source, [List<Object>? args]) =>
    FrappeTranslations.translate(source, args);
```

Until the host app wires a delegate, `tr` performs simple positional `{0}` / `{1}` substitution and returns the source string unchanged — no crashes, no null returns.

---

## Host app integration

### 1. Wire the delegate (Riverpod)

In the `translationListenerProvider` (called once from `ChetnaApp`):

```dart
// lib/core/sdk/translation_provider.dart
final translationListenerProvider = Provider<void>((ref) {
  final sdk = ref.watch(sdkProvider);

  // Wire global tr() helper to the initialized TranslationService
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

`_currentLocalizations` is a file-level variable (`AppLocalizations? _currentLocalizations`) that caches the most recently loaded locale. Because ARB loading is asynchronous but `translate` must be synchronous, the cache is refreshed on each locale change and the Riverpod tick triggers a full rebuild so widgets re-render with the new strings.

### 2. The ARB lookup extension

Flutter's generated `AppLocalizations` exposes only named getters (`l10n.save`, `l10n.login`). To look up by a string key at runtime, the project generates a switch-case extension:

```bash
dart run tools/generate_l10n_lookup.dart
```

This scans `lib/l10n/app_en.arb` and emits `lib/l10n/app_localizations_lookup.dart` with a `lookup(String key, ...)` extension on `AppLocalizations`. Re-run whenever you add or rename ARB keys.

### 3. Adding SDK strings to ARB

Every string called via `tr(...)` in the SDK that should be translated must have an entry in `app_en.arb` (and its `app_hi.arb` / `app_gu.arb` counterparts):

```json
// lib/l10n/app_en.arb
{
  "saveLabel": "Save",
  "@saveLabel": { "description": "Form save button label" },
  "savingEllipsis": "Saving...",
  "@savingEllipsis": {}
}
```

The ARB key must match the switch-case in the generated lookup. Keys are camelCase ARB identifiers; the lookup extension maps English source strings to those identifiers.

---

## SQLite translation cache

Independent of the ARB pipeline, `TranslationService` also maintains a SQLite KV cache (`translations_cache.db`) populated from the Frappe backend API (`mobile_auth.get_translations`). This covers dynamic doctype field labels and select option values that do not exist in ARB files.

| Source | What it covers | When loaded |
|---|---|---|
| ARB files | Fixed UI strings (buttons, headers, validators) | Compile-time, instant |
| SQLite cache | Dynamic field labels, select options from doctype meta | Startup (SQLite, <5 ms) + background refresh after login |

The `translate` method checks the `translateDelegate` (ARB) first; if the result equals the source, it falls through to `translateLocal` (SQLite). This means:

- UI strings that exist in ARB: always resolved correctly, even offline, even before API login
- Doctype field labels that exist only in the Frappe DB: resolved from SQLite cache on restart, refreshed from API in background

---

## Locale lifecycle

```
app launch
  └─ sdkInitProvider
       ├─ sdk.initialize()
       └─ sdk.translations.setLocale(storedLang)   ← SharedPreferences 'user_locale'
            ├─ loadFromCache(lang)                  ← SQLite, <5 ms
            └─ refreshAsync(lang)                   ← background network fetch

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
```

**First-frame guarantee:** On every launch after the first, the SQLite cache is pre-warmed before the form screen mounts. The user's language is correct from frame 1 — no flash of English.

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

## Adding a new translatable string

**Fixed UI string (button, label, error message):**

1. Call `tr('My string')` at the use site in the SDK widget.
2. Add to `lib/l10n/app_en.arb`:
   ```json
   "myStringKey": "My string",
   "@myStringKey": { "description": "Short description" }
   ```
3. Add translations to `app_hi.arb` and `app_gu.arb`.
4. Run `flutter gen-l10n` (host app).
5. Run `dart run tools/generate_l10n_lookup.dart` to regenerate the lookup extension.

**Dynamic field label (from Frappe doctype meta):**

No action needed — these flow through `TranslationService.translateLocal` via the SQLite cache, which is populated automatically from `mobile_auth.get_translations` on login.

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

## Why `tr` and not `__`

In Dart, any identifier beginning with `_` is library-private. A top-level function named `__` defined in `translate.dart` cannot be accessed from other files or from the host app, even if re-exported in the barrel file. `tr` starts with a public character and resolves normally across all library boundaries.
