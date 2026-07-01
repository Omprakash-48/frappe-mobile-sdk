import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// Tests for [FrappeFormBuilder.cascadeProgrammaticChanges] — Frappe
/// `frm.set_value` parity: a value set programmatically by [onFieldChange]
/// re-fires that field's own change handler so its dependents recompute.
///
/// Baseline (flag OFF) documents WHY the SDK does not cascade on its own: the
/// change pipeline writes the patch into form state *before* calling
/// `patchValue`, so the re-entrant `onChanged` sees `oldValue == value` and its
/// guard no-ops the handler. The flag forces that re-fire, loop-safely.
void main() {
  DocTypeMeta metaABC() => DocTypeMeta(
    name: 'TestDoctype',
    fields: <DocField>[
      DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
      DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
      DocField(fieldname: 'c', fieldtype: 'Data', label: 'C'),
    ],
  );

  // a='hello' ⇒ compute b; b changing ⇒ compute c; c terminates.
  Map<String, dynamic>? chainHandler(
    String name,
    dynamic value,
    Map<String, dynamic> data,
  ) {
    if (name == 'a' && value == 'hello') return {'b': 'B:hello'};
    if (name == 'b') return {'c': 'C:$value'};
    return null;
  }

  testWidgets('cascade OFF (default): a computed field does NOT chain', (
    tester,
  ) async {
    Map<String, dynamic>? emitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: metaABC(),
            // cascadeProgrammaticChanges defaults to false
            onFieldChange: chainHandler,
            onFormDataChanged: (d) => emitted = d,
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'hello');
    await tester.pumpAndSettle();

    expect(emitted?['b'], 'B:hello', reason: 'a→b direct patch still applies');
    expect(
      (emitted?['c'] ?? '').toString(),
      isEmpty,
      reason: 'without the flag, b must not re-fire its own handler → c unset',
    );
  });

  testWidgets('cascade ON: a computed field re-fires its handler (a→b→c)', (
    tester,
  ) async {
    Map<String, dynamic>? emitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: metaABC(),
            cascadeProgrammaticChanges: true,
            onFieldChange: chainHandler,
            onFormDataChanged: (d) => emitted = d,
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'hello');
    await tester.pumpAndSettle();

    expect(emitted?['b'], 'B:hello', reason: 'a→b direct patch');
    expect(
      emitted?['c'],
      'C:B:hello',
      reason: "b's programmatic set must cascade to c",
    );
  });

  testWidgets(
    'cascade ON: a typed (Check) computed field re-fires EXACTLY once',
    (tester) async {
      // Regression guard for the double-fire risk: the handler returns `1`
      // (int) for a Check field, which FieldNormalizer turns into `true`
      // (bool). Without the echo suppression, the synchronous patchValue echo
      // (oldValue 1 != true) AND the explicit cascade would both fire the
      // `flag` handler. It must fire exactly once.
      var flagHandlerCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'TestDoctype',
                fields: <DocField>[
                  DocField(fieldname: 'trigger', fieldtype: 'Data', label: 'T'),
                  DocField(fieldname: 'flag', fieldtype: 'Check', label: 'F'),
                ],
              ),
              cascadeProgrammaticChanges: true,
              onFieldChange: (name, value, data) {
                if (name == 'trigger') return {'flag': 1};
                if (name == 'flag') {
                  flagHandlerCalls++;
                  return null;
                }
                return null;
              },
            ),
          ),
        ),
      );

      await tester.enterText(find.byKey(const ValueKey('data_trigger')), 'x');
      await tester.pumpAndSettle();

      expect(
        flagHandlerCalls,
        1,
        reason: 'echo must be suppressed; only the explicit cascade fires',
      );
    },
  );

  testWidgets('cascade terminates on a non-converging handler (depth cap)', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: DocTypeMeta(
              name: 'TestDoctype',
              fields: <DocField>[
                DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
                DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
              ],
            ),
            cascadeProgrammaticChanges: true,
            onFieldChange: (name, value, data) {
              calls++;
              // b keeps setting itself to a NEW value ⇒ value-equality never
              // stops it; only the depth cap can. Proves the backstop.
              if (name == 'a') return {'b': '1'};
              if (name == 'b') {
                return {'b': '${(int.tryParse('$value') ?? 0) + 1}'};
              }
              return null;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const ValueKey('data_a')), 'go');
    await tester.pumpAndSettle();

    // The key assertion is that pumpAndSettle RETURNS (no infinite loop).
    // Calls are bounded: 1 for `a` + at most (depth cap) re-fires for `b`.
    expect(
      calls,
      lessThanOrEqualTo(20),
      reason: 'cascade must be bounded by the depth cap, not loop forever',
    );
    expect(calls, greaterThan(1), reason: 'the cascade did fire at least once');
  });
}
