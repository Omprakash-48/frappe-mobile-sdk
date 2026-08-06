import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';

void main() {
  group('spaced operators (existing grammar, regression)', () {
    test('eval:doc.x == 1 true/false', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x == 1', {'x': 1}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x == 1', {'x': 2}), isFalse);
    });

    test('eval:doc.x != "Yes"', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x != "Yes"', {'x': 'No'}),
        isTrue,
      );
    });

    test('bare truthy fieldname', () {
      expect(
        DependsOnEvaluator.evaluate('is_active', {'is_active': 1}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('is_active', {'is_active': 0}),
        isFalse,
      );
    });

    test('includes pattern', () {
      expect(
        DependsOnEvaluator.evaluate('eval:["A","B"].includes(doc.grade)', {
          'grade': 'B',
        }),
        isTrue,
      );
    });

    test('spaced && / ||', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a == 1 && doc.b == 2', {
          'a': 1,
          'b': 2,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a == 1 || doc.b == 2', {
          'a': 0,
          'b': 2,
        }),
        isTrue,
      );
    });
  });

  group('no-space operators (real-world Frappe metas)', () {
    test('eval:doc.x==1', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x==1', {'x': 1}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x==1', {'x': 2}), isFalse);
    });

    test('eval:doc.x!=1', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x!=1', {'x': 2}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x!=1', {'x': 1}), isFalse);
    });

    test('eval:doc.x>=3 and doc.x<=3', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 2}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.x<=3', {'x': 3}), isTrue);
    });

    test('eval:doc.x>3 and doc.x<3', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x<3', {'x': 2}), isTrue);
    });

    test('strict equality variants', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x==="Yes"', {'x': 'Yes'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x!=="Yes"', {'x': 'No'}),
        isTrue,
      );
    });

    test('no-space && and ||', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b==2', {
          'a': 1,
          'b': 2,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b==2', {
          'a': 1,
          'b': 3,
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1||doc.b==2', {
          'a': 0,
          'b': 2,
        }),
        isTrue,
      );
    });

    test('mixed spacing', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a ==1 && doc.b== 2', {
          'a': 1,
          'b': 2,
        }),
        isTrue,
      );
    });

    test('unspaced operator set stays intact after quote-aware collapse', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.qty==5', {'qty': 5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.qty>=5', {'qty': 5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.qty!=2', {'qty': 5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b!=2', {
          'a': 1,
          'b': 3,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b!=2', {
          'a': 1,
          'b': 2,
        }),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate('eval:doc.x<=3', {'x': 3}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x<3', {'x': 2}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 4}), isTrue);
    });

    test('negative numeric literal still parses', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.variance < -1', {'variance': -5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.variance < -1', {'variance': 0}),
        isFalse,
      );
    });
  });

  group('quote safety', () {
    test('operators inside quoted values are not torn apart', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status=="A && B"', {
          'status': 'A && B',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.status=='X==Y'", {
          'status': 'X==Y',
        }),
        isTrue,
      );
    });

    test('spaced operators inside quoted values are not torn apart', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.note == "a && b"', {
          'note': 'a && b',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.note == "a && b"', {
          'note': 'a || b',
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.note == "x==y"', {
          'note': 'x==y',
        }),
        isTrue,
      );
    });

    test('internal double space in a quoted literal is preserved (==)', () {
      // Regression: the operator-spacing pass copied quoted contents verbatim,
      // then a global `replaceAll(' {2,}', ' ')` on the finished string undid
      // that and rewrote the INSIDE of string literals. A Select option or Data
      // value carrying two consecutive spaces silently failed its comparison
      // and mis-gated visibility / mandatory / read-only.
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == "In  Progress"', {
          'status': 'In  Progress',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == "In  Progress"', {
          'status': 'In Progress',
        }),
        isFalse,
      );
    });

    test('internal double space in a quoted literal is preserved (!=)', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status != "In  Progress"', {
          'status': 'In  Progress',
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status != "In  Progress"', {
          'status': 'In Progress',
        }),
        isTrue,
      );
    });

    test('leading/trailing spaces inside the quotes are preserved', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == " Draft "', {
          'status': ' Draft ',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == " Draft "', {
          'status': 'Draft',
        }),
        isFalse,
      );
    });
  });

  group('JS arrow functions are not > comparisons', () {
    test('=> is parsed as an arrow, not as a > comparison', () {
      // Originally a white-box probe: operator-spacing normalization rewrote
      // `r => r.ok` to `r = > r.ok`, making the expression match the ' > '
      // comparison branch instead of falling through to the truthy fallback,
      // and the literal formData key the fallback consulted was the proof that
      // `=>` had survived intact.
      //
      // That fallback is gone — `eval:` expressions now go through a real JS
      // parser, which never consults a literal key. So the contract is asserted
      // directly instead: the arrow body actually runs, per row.
      const expr = 'eval:doc.items.some(r => r.ok)';
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'items': [
            {'ok': false},
            {'ok': true},
          ],
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'items': [
            {'ok': false},
          ],
        }),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate(expr, {'items': []}), isFalse);
      // Direct guard on the arrow itself: a self-contained array literal, so
      // the result depends only on whether `=>` parsed. Mangling it into
      // `= >` fails the parse, and BOTH cases would then fall back to
      // defaultOnError (true) — so the isFalse case cannot pass by accident.
      expect(
        DependsOnEvaluator.evaluate('eval:[1,2].some(r => r > 1)', {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:[1,2].some(r => r > 5)', {}),
        isFalse,
      );
      // The arrow parameter is not a document field, so it stays out of the
      // reverse-dependency graph.
      expect(DependsOnEvaluator.referencedFields(expr), {'items'});
    });

    test('real > / >= comparisons are unaffected by the arrow guard', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x > 3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 2}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.x >= 3', {'x': 3}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 2}), isFalse);
    });
  });

  group('leading ! (JS logical NOT)', () {
    test('negates a falsy field to true', () {
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': 0}),
        isTrue,
      );
      expect(DependsOnEvaluator.evaluate('eval:!doc.flag', {}), isTrue);
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': ''}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': false}),
        isTrue,
      );
    });

    test('negates a truthy field to false', () {
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': 1}),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': true}),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': 'x'}),
        isFalse,
      );
    });

    test('resolves the framework __islocal flag both ways', () {
      // `read_only_depends_on: eval:!doc.__islocal` is the common Frappe idiom
      // for "lock this field once the document has been saved".
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.__islocal', {'__islocal': 1}),
        isFalse, // unsaved -> not read-only -> editable
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.__islocal', {'__islocal': 0}),
        isTrue, // saved -> read-only
      );
    });

    test('composes with && and ||', () {
      expect(
        DependsOnEvaluator.evaluate(
          'eval:!doc.verified && doc.docstatus === 0',
          {'verified': 0, 'docstatus': 0},
        ),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(
          'eval:!doc.verified && doc.docstatus === 0',
          {'verified': 1, 'docstatus': 0},
        ),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.a || doc.b', {'a': 1, 'b': 1}),
        isTrue,
      );
    });

    test('!= and !== still reach their own comparison branches', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status !== "Open"', {
          'status': 'Closed',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status != "Open"', {
          'status': 'Open',
        }),
        isFalse,
      );
      // Unspaced forms go through operator-spacing normalization first.
      expect(DependsOnEvaluator.evaluate('eval:doc.x!=1', {'x': 2}), isTrue);
    });

    test('referencedFields sees through a negation', () {
      expect(DependsOnEvaluator.referencedFields('eval:!doc.__islocal'), {
        '__islocal',
      });
    });
  });

  group('missing docstatus defaults to 0 (Draft)', () {
    test('draft-only comparisons hold when the key is absent', () {
      // In Frappe a document always has a docstatus — 0 while it is a draft —
      // so desk treats eval:doc.docstatus === 0 as true on a new doc. Client
      // form data does not always carry the key.
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 0', {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus == 0', {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus !== 0', {}),
        isFalse,
      );
    });

    test('an explicit docstatus still wins', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 0', {
          'docstatus': 1,
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 1', {
          'docstatus': 1,
        }),
        isTrue,
      );
    });

    test('other missing fields are NOT defaulted', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.other === 0', {}), isFalse);
    });
  });

  // Shapes the old string-matching evaluator needed an operator-spacing pass to
  // survive, asserted against real JS semantics instead of that
  // implementation's limits. Unspaced operators, two-space literals and arrow
  // predicates are already covered above and in depends_on_evaluator_test.dart;
  // what was missing is a backslash-escaped quote, real arithmetic, and the
  // regex-literal contract.
  group('shapes that defeated the string-matching evaluator', () {
    test('an escaped quote does not end the string literal early', () {
      // `"it\"s ok"` is ONE JS literal holding `it"s ok`.
      expect(
        DependsOnEvaluator.evaluate(r'eval:doc.note == "it\"s ok"', {
          'note': 'it"s ok',
        }),
        isTrue,
      );
      // A comparison operator inside the literal is data, not an operator.
      expect(
        DependsOnEvaluator.evaluate(r'eval:doc.note == "a\"b>c"', {
          'note': 'a"b>c',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(r'eval:doc.note == "a\"b>c"', {
          'note': 'other',
        }),
        isFalse,
      );
    });

    test('a slash after a value is division, and it is really computed', () {
      // The matcher documented `doc.a/2 == 5` as false because it did no
      // arithmetic. Desk computes it, so a real answer is required here.
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a/2 == 5', {'a': 10}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a/2 == 5', {'a': 8}),
        isFalse,
      );
    });

    test('KNOWN LIMITATION: a regex literal falls back, it does not guess', () {
      // js_expression.dart deliberately does not lex regex literals, so such an
      // expression throws and the caller's per-property default is used — never
      // a computed boolean. Pinned via the differential: the two defaults
      // disagreeing proves the expression fell back rather than answering. This
      // fails loudly if regex support is ever half-implemented.
      const expr = r"eval:doc.html.replace(/<br>/g, '') == 'ab'";
      const data = <String, dynamic>{'html': 'a<br>b'};
      expect(
        DependsOnEvaluator.evaluate(expr, data, defaultOnError: true),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(expr, data, defaultOnError: false),
        isFalse,
      );
    });
  });
}
