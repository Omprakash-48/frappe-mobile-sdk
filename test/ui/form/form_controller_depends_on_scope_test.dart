import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

void main() {
  group('depends_on evaluation scope', () {
    test('parent.<field> resolves from parentData on a child-row form', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'qty': '1'},
        parentData: const {'kind': 'X'},
      );
      expect(c.uiStateOf('gated').value.visible, isTrue);
    });

    test('parent.<field> that does not match hides the field', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'qty': '1'},
        parentData: const {'kind': 'Y'},
      );
      expect(c.uiStateOf('gated').value.visible, isFalse);
    });

    test('mandatory_depends_on can read parent', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'reason',
            fieldtype: 'Data',
            mandatoryDependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        parentData: const {'kind': 'X'},
      );
      expect(c.uiStateOf('reason').value.required, isTrue);
    });

    test('with no parentData, parent aliases doc (as Frappe does)', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'kind', fieldtype: 'Data'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'kind': 'X'},
      );
      expect(c.uiStateOf('gated').value.visible, isTrue);
    });

    test('std fields (docstatus) are readable by depends_on', () {
      // docstatus is not in DocType.fields, so _seedDefaults would drop it and
      // `eval:doc.docstatus == 0` would hide a field Desk shows. The legacy
      // _formData path carries it via addAll(initialData); reactive mode must
      // match.
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'x', fieldtype: 'Data'),
          DocField(
            fieldname: 'draft_only',
            fieldtype: 'Data',
            dependsOn: 'eval:doc.docstatus == 0',
          ),
        ]),
        initialData: const {'x': '1', 'docstatus': 0},
      );
      expect(c.uiStateOf('draft_only').value.visible, isTrue);

      final submitted = FormController(
        meta: _meta([
          DocField(fieldname: 'x', fieldtype: 'Data'),
          DocField(
            fieldname: 'draft_only',
            fieldtype: 'Data',
            dependsOn: 'eval:doc.docstatus == 0',
          ),
        ]),
        initialData: const {'x': '1', 'docstatus': 1},
      );
      expect(submitted.uiStateOf('draft_only').value.visible, isFalse);
    });

    test('std fields stay OUT of the submit payload', () {
      final c = FormController(
        meta: _meta([DocField(fieldname: 'x', fieldtype: 'Data')]),
        initialData: const {
          'x': '1',
          'docstatus': 0,
          'name': 'T-0001',
          'owner': 'a@b.c',
          '__islocal': 1,
        },
      );
      final payload = c.buildSubmitData();
      expect(payload.containsKey('x'), isTrue);
      for (final k in ['docstatus', 'name', 'owner', '__islocal']) {
        expect(payload.containsKey(k), isFalse, reason: '$k leaked into save');
      }
    });

    // ── regression: the payload sweep must see the std fields ───────────────
    //
    // buildSubmitData strips _stdEvalFields from the payload map and used to
    // reuse that same map as the depends_on scope. A field gated on
    // `eval:doc.docstatus == 0` was therefore VISIBLE (uiState reads
    // _rawValues, which has docstatus), editable and validated — and then
    // silently dropped from the save, because in the payload scope
    // doc.docstatus was undefined and `undefined == 0` is false.
    //
    // The two tests above cannot catch this: the visibility one never calls
    // buildSubmitData, and the payload one uses a meta with no depends_on.
    group(
      'payload sweep evaluates against the full doc (std fields included)',
      () {
        test('a field gated on docstatus survives into the payload', () {
          final c = FormController(
            meta: _meta([
              DocField(fieldname: 'x', fieldtype: 'Data'),
              DocField(
                fieldname: 'draft_only',
                fieldtype: 'Data',
                dependsOn: 'eval:doc.docstatus == 0',
              ),
            ]),
            initialData: const {'x': '1', 'docstatus': 0},
          );
          c.setValue('draft_only', 'user typed this');

          expect(
            c.uiStateOf('draft_only').value.visible,
            isTrue,
            reason: 'precondition: the user can see and fill the field',
          );

          final payload = c.buildSubmitData();
          expect(
            payload['draft_only'],
            'user typed this',
            reason: 'a visible, user-filled field must not be dropped on save',
          );
          expect(
            payload.containsKey('docstatus'),
            isFalse,
            reason: 'the eval scope carries docstatus; the payload must not',
          );
        });

        test('a Section Break gated on docstatus keeps its children', () {
          // The amplifier: one gated container drops EVERY field beneath it.
          final c = FormController(
            meta: _meta([
              DocField(fieldname: 'x', fieldtype: 'Data'),
              DocField(
                fieldname: 'sec',
                fieldtype: 'Section Break',
                dependsOn: 'eval:doc.docstatus == 0',
              ),
              DocField(fieldname: 'a', fieldtype: 'Data'),
              DocField(fieldname: 'b', fieldtype: 'Data'),
            ]),
            initialData: const {'x': '1', 'docstatus': 0},
          );
          c.setValue('a', 'A');
          c.setValue('b', 'B');

          final payload = c.buildSubmitData();
          expect(payload['a'], 'A');
          expect(payload['b'], 'B');
        });

        test('a Tab Break gated on docstatus keeps its children', () {
          final c = FormController(
            meta: _meta([
              DocField(fieldname: 'x', fieldtype: 'Data'),
              DocField(
                fieldname: 'tab',
                fieldtype: 'Tab Break',
                dependsOn: 'eval:doc.docstatus == 0',
              ),
              DocField(fieldname: 'a', fieldtype: 'Data'),
            ]),
            initialData: const {'x': '1', 'docstatus': 0},
          );
          c.setValue('a', 'A');
          expect(c.buildSubmitData()['a'], 'A');
        });

        test('a genuinely hidden field is still dropped', () {
          // The sweep must keep working: docstatus 1 means "submitted", so a
          // draft-only field is legitimately gone from both UI and payload.
          final c = FormController(
            meta: _meta([
              DocField(fieldname: 'x', fieldtype: 'Data'),
              DocField(
                fieldname: 'draft_only',
                fieldtype: 'Data',
                dependsOn: 'eval:doc.docstatus == 0',
              ),
            ]),
            initialData: const {
              'x': '1',
              'docstatus': 1,
              'draft_only': 'stale',
            },
          );
          expect(c.uiStateOf('draft_only').value.visible, isFalse);
          expect(c.buildSubmitData().containsKey('draft_only'), isFalse);
        });

        test('__islocal from initialData reaches the payload sweep', () {
          final c = FormController(
            meta: _meta([
              DocField(fieldname: 'x', fieldtype: 'Data'),
              DocField(
                fieldname: 'new_only',
                fieldtype: 'Data',
                dependsOn: 'eval:doc.__islocal',
              ),
            ]),
            initialData: const {'x': '1', '__islocal': 1},
          );
          c.setValue('new_only', 'N');
          final payload = c.buildSubmitData();
          expect(payload['new_only'], 'N');
          expect(payload.containsKey('__islocal'), isFalse);
        });
      },
    );

    // ── regression: a new document has docstatus 0, as in Desk ──────────────
    group('missing docstatus defaults to 0', () {
      test('a draft-only field shows on a brand-new document', () {
        // frappe/public/js/frappe/model/create_new.js sets `newdoc.docstatus = 0`,
        // so Desk reads `eval:doc.docstatus == 0` as true on a new doc. Nothing
        // in the SDK stamps the key, and an absent docstatus made the same
        // expression false — hiding the field on every new document. Verified
        // against node: with docstatus absent, `doc.docstatus == 0` is false.
        final c = FormController(
          meta: _meta([
            DocField(fieldname: 'x', fieldtype: 'Data'),
            DocField(
              fieldname: 'draft_only',
              fieldtype: 'Data',
              dependsOn: 'eval:doc.docstatus == 0',
            ),
          ]),
          initialData: const {'x': '1'}, // no docstatus — a new doc
        );
        expect(c.uiStateOf('draft_only').value.visible, isTrue);
        c.setValue('draft_only', 'N');
        expect(c.buildSubmitData()['draft_only'], 'N');
      });

      test('an explicit docstatus in initialData still wins', () {
        final c = FormController(
          meta: _meta([
            DocField(
              fieldname: 'draft_only',
              fieldtype: 'Data',
              dependsOn: 'eval:doc.docstatus == 0',
            ),
          ]),
          initialData: const {'docstatus': 1},
        );
        expect(c.uiStateOf('draft_only').value.visible, isFalse);
      });

      test('a saved doc keeps its own docstatus semantics', () {
        final c = FormController(
          meta: _meta([
            DocField(
              fieldname: 'draft_only',
              fieldtype: 'Data',
              dependsOn: 'eval:doc.docstatus == 0',
            ),
          ]),
          initialData: const {'name': 'T-0001', 'docstatus': 0},
        );
        expect(c.uiStateOf('draft_only').value.visible, isTrue);
      });

      test(
        'the default does not leak into the payload or mark the form dirty',
        () {
          final c = FormController(
            meta: _meta([DocField(fieldname: 'x', fieldtype: 'Data')]),
            initialData: const {'x': '1'},
          );
          expect(c.buildSubmitData().containsKey('docstatus'), isFalse);
          expect(c.isDirty.value, isFalse);
        },
      );
    });

    // ── regression: __islocal is derived from the absence of a name ─────────
    //
    // Desk stamps `__islocal = 1` next to `docstatus = 0` on a new doc
    // (create_new.js:309-310) and drops it once the doc has a name; Frappe's own
    // new-doc test is `__islocal or not name` (document.py:539). Without the
    // derivation, `!doc.__islocal` reads `!undefined` == true and the SDK acts
    // as though every document were already saved.
    group('missing __islocal is derived from the absence of a name', () {
      DocTypeMeta savedOnlyMeta() => _meta([
        DocField(fieldname: 'x', fieldtype: 'Data'),
        DocField(
          fieldname: 'saved_only',
          fieldtype: 'Data',
          dependsOn: 'eval:!doc.__islocal',
        ),
      ]);

      test('a saved-only field is HIDDEN on a new document', () {
        // The dominant corpus form: 10+ uses of `eval:!doc.__islocal`.
        final c = FormController(
          meta: savedOnlyMeta(),
          initialData: const {'x': '1'}, // no name -> local
        );
        expect(c.uiStateOf('saved_only').value.visible, isFalse);
      });

      test('a saved-only field is VISIBLE once the doc has a name', () {
        final c = FormController(
          meta: savedOnlyMeta(),
          initialData: const {'x': '1', 'name': 'T-0001'},
        );
        expect(c.uiStateOf('saved_only').value.visible, isTrue);
      });

      test('an empty name still counts as local', () {
        final c = FormController(
          meta: savedOnlyMeta(),
          initialData: const {'x': '1', 'name': ''},
        );
        expect(c.uiStateOf('saved_only').value.visible, isFalse);
      });

      test('read_only_depends_on must not lock a new-document field', () {
        // The worst shape: the user cannot type into the field at all.
        final c = FormController(
          meta: _meta([
            DocField(
              fieldname: 'f',
              fieldtype: 'Data',
              readOnlyDependsOn: 'eval:!doc.__islocal',
            ),
          ]),
        );
        expect(c.uiStateOf('f').value.readOnly, isFalse);
        final saved = FormController(
          meta: _meta([
            DocField(
              fieldname: 'f',
              fieldtype: 'Data',
              readOnlyDependsOn: 'eval:!doc.__islocal',
            ),
          ]),
          initialData: const {'name': 'T-1'},
        );
        expect(saved.uiStateOf('f').value.readOnly, isTrue);
      });

      test('an explicit __islocal from the host wins over the derivation', () {
        // A host that knows better: no name, but explicitly not local.
        final c = FormController(
          meta: savedOnlyMeta(),
          initialData: const {'x': '1', '__islocal': 0},
        );
        expect(c.uiStateOf('saved_only').value.visible, isTrue);
      });

      test('the derived flag stays out of the submit payload', () {
        final c = FormController(
          meta: _meta([DocField(fieldname: 'x', fieldtype: 'Data')]),
          initialData: const {'x': '1'},
        );
        final payload = c.buildSubmitData();
        expect(payload.containsKey('__islocal'), isFalse);
        expect(c.isDirty.value, isFalse);
      });
    });

    // ── regression: a host-supplied controller must still get `parent` ──────
    test('parentData can be wired after construction', () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'qty', fieldtype: 'Int'),
          DocField(
            fieldname: 'gated',
            fieldtype: 'Data',
            dependsOn: "eval:parent.kind == 'X'",
          ),
        ]),
        initialData: const {'qty': '1'},
      );
      // With no parentData, `parent` aliases `doc`, which has no `kind`.
      expect(c.uiStateOf('gated').value.visible, isFalse);

      c.parentData = const {'kind': 'X'};

      expect(
        c.uiStateOf('gated').value.visible,
        isTrue,
        reason: 'the setter must recompute UI state for observed fields',
      );
      expect(c.parentData, const {'kind': 'X'});
    });

    test(
      'a post-validate parentData change cannot let a submit through stale',
      () {
        // The setter does not re-run validation, so the DISPLAYED errors lag by
        // design. What must never lag is the save gate: validate() clears
        // _errors and re-derives from the live UI state the setter refreshed.
        final c = FormController(
          meta: _meta([
            DocField(fieldname: 'qty', fieldtype: 'Int'),
            DocField(
              fieldname: 'reason',
              fieldtype: 'Data',
              mandatoryDependsOn: "eval:parent.kind == 'X'",
            ),
          ]),
          initialData: const {'qty': '1'},
        );
        // Not required yet -> the form validates clean.
        expect(c.validate(), isTrue);
        expect(c.uiStateOf('reason').value.required, isFalse);

        c.parentData = const {'kind': 'X'};

        // The field is required now...
        expect(c.uiStateOf('reason').value.required, isTrue);
        // ...and the next validation catches the empty value.
        expect(
          c.validate(),
          isFalse,
          reason:
              'validate() must re-derive required from the refreshed UI state',
        );
        expect(c.firstInvalidField, 'reason');
      },
    );
  });
}
