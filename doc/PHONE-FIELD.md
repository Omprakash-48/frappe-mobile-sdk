# PhoneField

`PhoneField` is the SDK widget for fields with `fieldtype = 'Phone'`. It enforces a fixed country-code prefix (India, `+91`) so stored values are always in the canonical form `+91<10 digits>` (e.g. `+919876543210`). The user types the 10-digit number only; the prefix is displayed via `InputDecoration.prefixText` and never touches the controller.

---

## Storage contract

| Layer | Value | Example |
|-------|-------|---------|
| SQLite `docs__*` / server | `+<dialcode><digits>` | `+919876543210` |
| `FormBuilderField.value` | same as SQLite | `+919876543210` |
| `_controller.text` (internal) | digits only, no prefix | `9876543210` |
| Display (`prefixText`) | `+91 ` (non-editable prefix text) | user sees `+91 9876543210` |

The controller and the stored value are kept in separate namespaces deliberately.

---

## Key static helpers

### `toStored(String numberDigits) → String`

Converts raw digit input to the stored form. Strips all non-digits first as a safety belt, then prepends `_defaultDialCode`:

```dart
static String toStored(String numberDigits) {
  final digits = numberDigits.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.isEmpty) return '';
  return '$_defaultDialCode$digits';   // '+91' + digits
}
```

Called from `onNumberChanged` with the value the user typed (already pure digits by the time it arrives, but the strip is a defensive second pass).

### `numberFromStored(String? stored) → String`

The exact inverse of `toStored`. Strips the `+91` prefix (or the numeric equivalent `91` at the start of a 12-digit string) and returns the 10-digit number only.

The two helpers satisfy the **round-trip invariant**:

```
numberFromStored(toStored(digits)) == digits    ∀ non-empty digit strings
```

This invariant is what makes the echo-guard work.

---

## Echo guard — why there is no OOM or infinite loop

Earlier implementations of Phone handling (prior to `PhoneField`) used a plain `FormBuilderTextField` with `+91` prepended in `onChanged`. This caused a publish-subscribe loop:

1. User types `9` → `onChanged` emits `+919`
2. FormBuilder patches the field value to `+919`
3. `patchValue` triggers another `onChanged`(echo)
4. `onChanged` prepends again → `+91+919` → another patch → ...

This crashed with a `StackOverflowError` within milliseconds.

`PhoneField` breaks the loop by decoupling the **visible controller** from the **FormBuilder value**:

```
User types      →  _controller.text (digits only)
                          │
                          ▼
                   onChanged(text) strips non-digits → '9876543210'
                          │
                          ▼
              onNumberChanged('9876543210')
                          │
                          ▼
                 toStored('9876543210') = '+919876543210'
                          │
                          ├─▶ state.didChange('+919876543210')   ← FormBuilder value
                          └─▶ onChanged?.call('+919876543210')   ← host form callback
                                         │
                                         ▼
                        FormBuilder rebuild (storedValue = '+919876543210')
                                         │
                                         ▼
                        didUpdateWidget called on _PhoneNumberInput
                            incoming = numberFromStored('+919876543210')
                                      = '9876543210'
                            incoming == _controller.text ('9876543210')
                                ─▶ NO controller write  ← loop terminates
```

**The guard holds as long as `numberFromStored(toStored(x)) == x`.** Since both functions are written as pure inverses, this is unconditionally true for any non-empty digit string.

### What `prefixText` does and does not do

`InputDecoration.prefixText` renders `+91 ` before the cursor in the Flutter UI but:
- is **not** part of `_controller.text`
- is **not** passed to `onChanged`
- is **not** affected by `toStored` / `numberFromStored`

The user sees `+91 9876543210`; the controller holds `9876543210`. This visual separation is permanent — the prefix cannot accidentally find its way into the stored value.

---

## Regression history

### Regression in commit `0a33fbe` (2026-06-09)

The translation-pipeline commit accidentally rewrote `toStored` to call `numberFromStored` — the inverse operation:

```dart
// BROKEN (0a33fbe)
static String toStored(String numberDigits) {
  return numberFromStored(numberDigits);   // strips +91 instead of adding it
}
```

Effect: every phone entered or edited on device was stored as bare digits (`9876543210`) with no country code, while existing server records held `+919876543210`. Storage became heterogeneous. The phone validation length check (`>= 10 digits`) still passed because bare digits have 10 digits, so nothing caught the regression except the server's format check.

The test file was updated in the same commit to expect bare digits, keeping CI green.

**Fix (commit `e5aa19d`):** reverted `toStored` to the `df92de5` form (prepend `_defaultDialCode`) and restored test expectations to `+919876543210`.

### No OOM regression

The revert does **not** reintroduce the original `StackOverflowError`. The echo-guard invariant (`numberFromStored(toStored(x)) == x`) holds with the fixed `toStored`. The controller is never updated in `didUpdateWidget` when the stored value was produced by the user's own keystroke, so there is no cycle.

---

## Handling legacy bare-digit values

If a local SQLite row contains a bare-digit phone (e.g. from a period with the broken `toStored`), the field renders correctly:

1. `initialStored = '9876543210'`
2. `initState`: `_controller = TextEditingController(text: numberFromStored('9876543210'))` → `'9876543210'`
3. User sees `+91 9876543210` in the UI
4. On next edit + save, `toStored('9876543210')` = `'+919876543210'` → value is upgraded

Records never edited again persist as bare digits until the server normalises them. Frappe server-side validation will reject bare-digit phone values anyway, so they surface as sync errors and the user must re-enter.

---

## Validation

`_validate` checks `_digitsOnly(stored).length >= 10`. For a stored `'+919876543210'`, `_digitsOnly` returns `'919876543210'` (12 digits) which is `>= 10` — passes. For a bare-digit value `'9876543210'`, it also passes (10 digits). The validator is intentionally permissive about format to support both legacy and new data; the country-code contract is enforced by `toStored`, not the validator.

---

## Integration checklist

- The field emits `+91<digits>` or `null` (empty field) on change and on submit.
- Never pass a `value` that already went through `toStored` to `toStored` again — the function double-invokes `replaceAll(non-digits)` as a safety belt, which strips `+` and would produce `919876543210` instead of `+919876543210`. The call chain (`onChanged` in `_PhoneNumberInputState.build`) already strips non-digits before passing to `onNumberChanged`, so this path is unreachable in normal usage.
- If you need to display a stored value outside the field (e.g. in a list screen), call `numberFromStored(storedValue)` to get the 10-digit form and display it alongside a `+91 ` prefix manually.
