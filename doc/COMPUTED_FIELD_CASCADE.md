# Computed-field cascade (Frappe `set_value` parity)

By default, a value written into the form by an [`onFieldChange`](FIELD_CHANGE_HANDLER.md)
patch (a computed value, or a value derived from a `fetch_from`) does **not** re-fire that
field's own change handler. So a computed field that feeds *another* computed field stops
after one hop.

This differs from Frappe Desk, where `frm.set_value(fieldname, value)` fires that field's
change trigger even for a programmatic set — so chained computations "just work".

`FrappeFormBuilder.cascadeProgrammaticChanges` restores that behaviour, opt-in.

## Why the default doesn't cascade

The change pipeline writes the patch into form state **before** calling `patchValue`:

```dart
_formData.addAll(patches);
_formKey.currentState?.patchValue(_normalizePatchValues(patches));
```

`patchValue` does re-enter the field's `onChanged` (via `didChange`), but by then
`oldValue == value` (the value is already stored), so the pipeline's own
`oldValue != value` guard no-ops it. The programmatic set never triggers the field's
`onFieldChange`.

## Enabling

```dart
FrappeFormBuilder(
  meta: meta,
  cascadeProgrammaticChanges: true, // default: false
  onFieldChange: (fieldName, value, formData) {
    if (fieldName == 'dispatch_order_id') return {'commodity_code': /* fetched */};
    if (fieldName == 'commodity_code')    return {'uom': /* fetched from commodity */};
    // With the flag on, setting commodity_code above re-fires this handler → uom.
    return null;
  },
)
```

## Loop safety

The cascade is bounded by two independent mechanisms:

- **Value-equality (primary).** A field re-fires only when its value actually *changed*
  versus the value it held before the patch. A converged field re-emits its current value ⇒
  equal ⇒ no re-fire, so the cascade reaches a fixpoint. (A cross-field visited-set is
  deliberately **not** used — it would break legitimate fan-in, e.g. `A` sets `B` and `C`,
  both of which feed `D`.)
- **Depth cap (backstop).** Recursion is capped (currently 12 levels) to bound a
  non-converging handler (e.g. an `A ↔ B` flip-flop). Hitting the cap logs via `sdkLog` and
  stops.

The synchronous `patchValue` echo is suppressed while cascading, so each handler fires
**exactly once** — this matters for typed fields whose representation `FieldNormalizer`
changes (`Check` `1`→`true`, `Date` `String`→`DateTime`, `Rating` `String`→`int`), where the
echo would otherwise not self-guard and would double-run the handler.

## Backwards compatibility

- **Default `false`.** An unchanged consumer sees byte-for-byte identical behaviour — the flag
  gates every new code path.
- **Per-form.** Enable it only on forms whose `onFieldChange` handlers are known to be safe to
  re-enter. Handlers that issue network calls on change should be reviewed before enabling, so
  a cascade doesn't fan out unexpected requests.
- **Deterministic.** With the flag off, no scheduling, no re-fire, no depth tracking.

See also: [`doc/FIELD_CHANGE_HANDLER.md`](FIELD_CHANGE_HANDLER.md).
