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
    test('=> is not spaced apart, so the > branch is not taken', () {
      // `r => r.ok` was rewritten to `r = > r.ok`, which made the expression
      // match the ' > ' comparison branch instead of falling through to the
      // truthy fallback as it did before operator spacing was introduced.
      // The fallback looks the expression up with `doc.` stripped, so the key
      // it consults is proof that `=>` survived normalization intact.
      const expr = 'eval:doc.items.some(r => r.ok)';
      expect(
        DependsOnEvaluator.evaluate(expr, {'items.some(r => r.ok)': 1}),
        isTrue,
      );
      // The mangled key the buggy spacing produced is never consulted.
      expect(
        DependsOnEvaluator.evaluate(expr, {'items.some(r = > r.ok)': 1}),
        isFalse,
      );
    });

    test('real > / >= comparisons are unaffected by the arrow guard', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x > 3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 2}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.x >= 3', {'x': 3}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 2}), isFalse);
    });
  });
}
