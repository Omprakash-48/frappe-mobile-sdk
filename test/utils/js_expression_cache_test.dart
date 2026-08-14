import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';
import 'package:frappe_mobile_sdk/src/utils/js_expression.dart';

void main() {
  group('parse failures are cached', () {
    // A parse failure is deterministic — the source is static DocType meta —
    // but only successes were memoised, so the tokenizer and parser re-ran and
    // re-threw on EVERY evaluation. _computeUiState runs per field per change,
    // so one unparseable depends_on on a large form paid that cost on every
    // keystroke: exactly what the AST cache exists to avoid.
    const bad = 'doc.a +++ ';

    test('the same exception instance is rethrown, not rebuilt', () {
      Object? first;
      Object? second;
      try {
        parseJsExpression(bad);
      } catch (e) {
        first = e;
      }
      try {
        parseJsExpression(bad);
      } catch (e) {
        second = e;
      }
      expect(first, isA<JsEvalException>());
      expect(
        identical(first, second),
        isTrue,
        reason:
            'a cached failure is rethrown; a re-parse would build a new one',
      );
    });

    test('a successful parse is still memoised', () {
      final a = parseJsExpression('doc.x == 1');
      final b = parseJsExpression('doc.x == 1');
      expect(identical(a, b), isTrue);
    });

    test('caching a failure does not change the evaluation result', () {
      // Still the per-property default, on the first call and every one after.
      for (var i = 0; i < 3; i++) {
        expect(DependsOnEvaluator.evaluate('eval:$bad', const {}), isTrue);
        expect(
          DependsOnEvaluator.evaluate2('eval:$bad', const {}, false),
          isFalse,
        );
      }
    });
  });

  group('evaluation failures are logged once per expression', () {
    late DebugPrintCallback original;
    late List<String> lines;

    setUp(() {
      lines = <String>[];
      original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) lines.add(message);
      };
      DependsOnEvaluator.resetLogGateForTest();
    });

    tearDown(() {
      debugPrint = original;
      DependsOnEvaluator.resetLogGateForTest();
    });

    test('an unparseable expression is reported once, not per call', () {
      const bad = 'eval:doc.a +++ ';
      for (var i = 0; i < 25; i++) {
        DependsOnEvaluator.evaluate(bad, const {});
      }
      final reports = lines.where((l) => l.contains('cannot evaluate')).length;
      expect(
        reports,
        1,
        reason: 'a deterministic failure on static meta must not log 25 times',
      );
    });

    test('distinct expressions are each reported', () {
      DependsOnEvaluator.evaluate('eval:doc.a +++ ', const {});
      DependsOnEvaluator.evaluate('eval:doc.b +++ ', const {});
      expect(lines.where((l) => l.contains('cannot evaluate')).length, 2);
    });

    test('the fn: notice is also deduped', () {
      for (var i = 0; i < 10; i++) {
        DependsOnEvaluator.evaluate('fn:my_handler', const {});
      }
      expect(lines.where((l) => l.contains('"fn:"')).length, 1);
    });

    test('a successful evaluation logs nothing', () {
      DependsOnEvaluator.evaluate('eval:doc.a == 1', const {'a': 1});
      expect(lines, isEmpty);
    });
  });
}
