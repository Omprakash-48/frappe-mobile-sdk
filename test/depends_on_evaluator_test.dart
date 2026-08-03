import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';

void main() {
  group('DependsOnEvaluator', () {
    group('existing operators still work', () {
      test('== comparison', () {
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status == 'Yes'", {
            'status': 'Yes',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status == 'Yes'", {
            'status': 'No',
          }),
          isFalse,
        );
      });

      test('!= comparison', () {
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status != 'Yes'", {
            'status': 'No',
          }),
          isTrue,
        );
      });

      test('&& operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.category == 'TypeA' && doc.verified == 'Yes'",
            {'category': 'TypeA', 'verified': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.category == 'TypeA' && doc.verified == 'Yes'",
            {'category': 'TypeA', 'verified': 'No'},
          ),
          isFalse,
        );
      });

      test('|| operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.flag_a == 'Yes' || doc.flag_b == 'Yes'",
            {'flag_a': 'No', 'flag_b': 'Yes'},
          ),
          isTrue,
        );
      });

      test('null/empty expression returns true', () {
        expect(DependsOnEvaluator.evaluate(null, {}), isTrue);
        expect(DependsOnEvaluator.evaluate('', {}), isTrue);
      });

      test('truthy field check', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.active', {'active': 'Yes'}),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.active', {'active': ''}),
          isFalse,
        );
        expect(DependsOnEvaluator.evaluate('eval:doc.active', {}), isFalse);
      });

      test('trailing semicolon on int comparison is stripped', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.enabled_flag == 1;', {
            'enabled_flag': 1,
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.enabled_flag == 1;', {
            'enabled_flag': 0,
          }),
          isFalse,
        );
      });

      test('trailing semicolon on string comparison is stripped', () {
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status == 'Yes';", {
            'status': 'Yes',
          }),
          isTrue,
        );
      });
    });

    group('.includes() array expressions', () {
      test('single-quoted values — match', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category)",
            {'category': 'TypeB'},
          ),
          isTrue,
        );
      });

      test('single-quoted values — no match', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category)",
            {'category': 'TypeC'},
          ),
          isFalse,
        );
      });

      test('single-quoted values — field is null', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['Yes','No'].includes(doc.answer)",
            {},
          ),
          isFalse,
        );
      });

      test('double-quoted values', () {
        expect(
          DependsOnEvaluator.evaluate(
            'eval:["Male","Female"].includes(doc.gender)',
            {'gender': 'Female'},
          ),
          isTrue,
        );
      });

      test('.includes() combined with && operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category) && doc.status == 'Yes'",
            {'category': 'TypeA', 'status': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category) && doc.status == 'Yes'",
            {'category': 'TypeA', 'status': 'No'},
          ),
          isFalse,
        );
      });

      test('.includes() combined with || operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['Admin','Manager'].includes(doc.role) || doc.override == 'Yes'",
            {'role': 'User', 'override': 'Yes'},
          ),
          isTrue,
        );
      });

      test('empty array always false', () {
        expect(
          DependsOnEvaluator.evaluate("eval:[].includes(doc.field)", {
            'field': 'anything',
          }),
          isFalse,
        );
      });
    });

    group('grouping with parens', () {
      test('outer parens around a single AND group are stripped', () {
        expect(
          DependsOnEvaluator.evaluate("eval:(doc.a == 'X' && doc.b == 'Y')", {
            'a': 'X',
            'b': 'Y',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate("eval:(doc.a == 'X' && doc.b == 'Y')", {
            'a': 'X',
            'b': 'Z',
          }),
          isFalse,
        );
      });

      test('two AND groups joined by || — first true', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(doc.a == 'X' && doc.b == 'Y') || (doc.c == 'Z' && doc.d == 'W')",
            {'a': 'X', 'b': 'Y'},
          ),
          isTrue,
        );
      });

      test('two AND groups joined by || — second true', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(doc.a == 'X' && doc.b == 'Y') || (doc.c == 'Z' && doc.d == 'W')",
            {'c': 'Z', 'd': 'W'},
          ),
          isTrue,
        );
      });

      test('two AND groups joined by || — both false', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(doc.a == 'X' && doc.b == 'Y') || (doc.c == 'Z' && doc.d == 'W')",
            {'a': 'X', 'b': 'NO', 'c': 'Z', 'd': 'NO'},
          ),
          isFalse,
        );
      });

      test('paren group containing .includes mixed with == ', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(['A','B'].includes(doc.cat) && doc.flag == 'Yes')",
            {'cat': 'A', 'flag': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(['A','B'].includes(doc.cat) && doc.flag == 'Yes')",
            {'cat': 'C', 'flag': 'Yes'},
          ),
          isFalse,
        );
      });

      test('Frappe section_break_presence regression', () {
        // Verbatim from snf household_survey_family_member.json — was hidden
        // on mobile because parens grouping was not respected.
        const expr =
            "eval:(['5 Years to Less than 15 Years','15 Years and Above'].includes(doc.age_grup) && doc.study == 'No')"
            " || (doc.age_grup == '15 Years and Above' && doc.study == 'Yes' && doc.study_cont == 'No' && ['Anganwadi','Primary 1 to 2','Primary 3 to 5'].includes(doc.lst_pssd_clss))";

        // Branch 1: 15+ and study=No → section visible.
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': '15 Years and Above',
            'study': 'No',
          }),
          isTrue,
        );

        // Branch 2: 15+, study=Yes, dropped out at primary → section visible.
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': '15 Years and Above',
            'study': 'Yes',
            'study_cont': 'No',
            'lst_pssd_clss': 'Primary 3 to 5',
          }),
          isTrue,
        );

        // Neither branch matches → section hidden.
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': 'Less than 5 Years',
            'study': 'No',
          }),
          isFalse,
        );
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': '15 Years and Above',
            'study': 'Yes',
            'study_cont': 'Yes',
          }),
          isFalse,
        );
      });

      test('nested parens flatten correctly', () {
        expect(
          DependsOnEvaluator.evaluate("eval:((doc.a == 'X'))", {'a': 'X'}),
          isTrue,
        );
      });
    });

    group('relational comparisons coerce string operands', () {
      // Frappe often carries numeric field values as strings (a Float field
      // read back as "10.0", a computed value round-tripped through a text
      // field). JS depends_on coerces those; these guard that the Dart
      // evaluator matches instead of silently returning false.

      test('numeric-string > number is coerced (regression: qty_variance)', () {
        // The exact shape that hid the "Rejection Details" child table:
        // qty_variance arrived as the String "10.0", not double 10.0.
        expect(
          DependsOnEvaluator.evaluate('eval:doc.qty_variance > 0', {
            'qty_variance': '10.0',
          }),
          isTrue,
        );
      });

      test('num operands still compare (no behavior change)', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x > 0', {'x': 5.0}),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x > 0', {'x': 0}),
          isFalse,
        );
      });

      test('string "0.0" is not > 0 (boundary preserved)', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x > 0', {'x': '0.0'}),
          isFalse,
        );
      });

      test('<, >=, <= coerce strings symmetrically', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x < 20', {'x': '10.0'}),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x >= 10', {'x': '10'}),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x <= 5', {'x': '10.0'}),
          isFalse,
        );
      });

      test('field-vs-field: two numeric strings compare NUMERICALLY', () {
        // FieldNormalizer stringifies Int/Float/Currency/Percent, so both sides
        // arrive as String. Plain JS would compare "10" > "9" lexicographically
        // (false); Desk holds real numbers and says true. Follow Desk.
        expect(
          DependsOnEvaluator.evaluate('eval:doc.qty > doc.max_qty', {
            'qty': '10',
            'max_qty': '9',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.a < doc.b', {
            'a': '9',
            'b': '10',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.a >= doc.b', {
            'a': '2.50',
            'b': '2.5',
          }),
          isTrue,
        );
      });

      test('genuine text operands still compare lexicographically', () {
        expect(
          DependsOnEvaluator.evaluate("eval:doc.a < 'abd'", {'a': 'abc'}),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate("eval:doc.a > 'abd'", {'a': 'abc'}),
          isFalse,
        );
      });

      test('non-numeric / null / missing operand → false, never throws', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x > 0', {'x': 'abc'}),
          isFalse,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.x > 0', {'x': null}),
          isFalse,
        );
        expect(DependsOnEvaluator.evaluate('eval:doc.x > 0', {}), isFalse);
      });
    });
  });

  // Oracle for every test below: Frappe's `evaluate_depends_on_value`
  // (frappe/public/js/frappe/form/layout.js). For an `eval:` expression it
  // calls `frappe.utils.eval(expr, {doc, parent})`, i.e. real JS via
  // `new Function` — so JS truthiness and JS operator semantics apply.
  // Only the BARE (non-`eval:`) form uses the special array rule
  // `$.isArray(value) ? !!value.length : !!value`.
  group('MultiSelect / list-valued fields', () {
    // 'Multi Select' and Select+allowMultiple normalize to List<String>
    // (FieldNormalizer._normalizeMultiSelect); 'Table MultiSelect' holds
    // List<Map> rows keyed by the child doctype's inner Link fieldname
    // (TableMultiSelectFieldBase._emitCleanValue).

    test('bare (non-eval) form: empty list is falsy, non-empty truthy', () {
      // Frappe: `$.isArray(value) → !!value.length`.
      expect(DependsOnEvaluator.evaluate('ms', {'ms': <String>[]}), isFalse);
      expect(
        DependsOnEvaluator.evaluate('ms', {
          'ms': ['A'],
        }),
        isTrue,
      );
      expect(DependsOnEvaluator.evaluate('tms', {'tms': <dynamic>[]}), isFalse);
    });

    test('eval: form keeps JS truthiness — [] is TRUTHY', () {
      // NOT a bug: in JS `[]` is truthy, so `eval:doc.ms` shows the field even
      // when nothing is selected. Locked in to prevent an over-eager "fix".
      expect(
        DependsOnEvaluator.evaluate('eval:doc.ms', {'ms': <String>[]}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.ms', {
          'ms': ['A'],
        }),
        isTrue,
      );
      // null/absent is still falsy.
      expect(DependsOnEvaluator.evaluate('eval:doc.ms', {'ms': null}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.ms', {}), isFalse);
    });

    test('.length on a list', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.ms.length > 0', {
          'ms': ['A'],
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.ms.length > 0', {
          'ms': <String>[],
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.ms.length == 0', {
          'ms': <String>[],
        }),
        isTrue,
      );
      // .length on an absent field throws in JS; default-on-error applies.
      expect(DependsOnEvaluator.evaluate('eval:doc.ms.length > 0', {}), isTrue);
    });

    test('membership: doc.<multiselect>.includes(value)', () {
      expect(
        DependsOnEvaluator.evaluate("eval:doc.ms.includes('A')", {
          'ms': ['A', 'B'],
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.ms.includes('Z')", {
          'ms': ['A', 'B'],
        }),
        isFalse,
      );
    });

    test('== against a list coerces via join(",") like JS', () {
      // JS: ['A'] == 'A'  → true   (Array→primitive is join(','))
      expect(
        DependsOnEvaluator.evaluate("eval:doc.ms == 'A'", {
          'ms': ['A'],
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.ms == 'A'", {
          'ms': ['B'],
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.ms == 'A,B'", {
          'ms': ['A', 'B'],
        }),
        isTrue,
      );
      // === is strict: no coercion, a List never equals a String.
      expect(
        DependsOnEvaluator.evaluate("eval:doc.ms === 'A'", {
          'ms': ['A'],
        }),
        isFalse,
      );
    });

    test('Table MultiSelect: .some() with an arrow fn over child rows', () {
      // Verbatim production shape: present_season is a Table MultiSelect whose
      // child rows are {<inner link fieldname>: value}.
      const expr =
          'eval:(doc.present_season || []).some(r => r.season == "Kharif")';
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'present_season': [
            {'season': 'Kharif'},
          ],
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'present_season': [
            {'season': 'Rabi'},
            {'season': 'Kharif'},
          ],
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'present_season': [
            {'season': 'Rabi'},
          ],
        }),
        isFalse,
      );
      // The `|| []` guard must survive a null/absent child table.
      expect(
        DependsOnEvaluator.evaluate(expr, {'present_season': null}),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate(expr, {}), isFalse);
    });

    test('Table MultiSelect: every / filter / map over child rows', () {
      final data = {
        'present_season': [
          {'season': 'Kharif'},
          {'season': 'Rabi'},
        ],
      };
      expect(
        DependsOnEvaluator.evaluate(
          'eval:doc.present_season.every(r => r.season != "Zaid")',
          data,
        ),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(
          'eval:doc.present_season.filter(r => r.season == "Rabi").length == 1',
          data,
        ),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(
          'eval:doc.present_season.map(r => r.season).includes("Kharif")',
          data,
        ),
        isTrue,
      );
    });
  });

  group('Frappe core eval conditions', () {
    test('whitespace around operators is irrelevant', () {
      // Regression: the old splitter required literal ' == ' / ' && ' and
      // silently returned false for every compact expression.
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a=='X'", {'a': 'X'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a=='X'&&doc.b=='Y'", {
          'a': 'X',
          'b': 'Y',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a=='X'&&doc.b=='Y'", {
          'a': 'X',
          'b': 'Z',
        }),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate('eval:doc.n>5', {'n': 10}), isTrue);
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a=='1'||doc.b=='1'||doc.c=='1'", {
          'c': '1',
        }),
        isTrue,
      );
    });

    test('unary negation', () {
      expect(DependsOnEvaluator.evaluate('eval:!doc.x', {'x': ''}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:!doc.x', {'x': 'Yes'}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:!doc.x', {}), isTrue);
      expect(
        DependsOnEvaluator.evaluate("eval:!doc.x && doc.y=='1'", {'y': '1'}),
        isTrue,
      );
    });

    test('ternary', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a ? true : false', {'a': 'Y'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a ? doc.b=='1' : doc.c=='1'", {
          'a': 'Y',
          'b': '1',
        }),
        isTrue,
      );
    });

    test('parenthesised subexpression as an operand', () {
      expect(
        DependsOnEvaluator.evaluate("eval:(doc.a || doc.b) && doc.c=='1'", {
          'b': 'Y',
          'c': '1',
        }),
        isTrue,
      );
    });

    test('in_list / cint / flt / cstr helpers', () {
      expect(
        DependsOnEvaluator.evaluate("eval:in_list(['A','B'], doc.a)", {
          'a': 'A',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:in_list(['A','B'], doc.a)", {
          'a': 'C',
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:cint(doc.n) > 1', {'n': '2'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:flt(doc.n) > 1.5', {'n': '2.25'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:cstr(doc.n) == '2'", {'n': 2}),
        isTrue,
      );
    });

    test('docstatus / numeric system fields', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus == 0', {
          'docstatus': 0,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus == 0', {
          'docstatus': 1,
        }),
        isFalse,
      );
    });

    test('parent.<field> resolves for child-row expressions', () {
      expect(
        DependsOnEvaluator.evaluate(
          "eval:parent.kind == 'X'",
          {'qty': 1},
          parentData: {'kind': 'X'},
        ),
        isTrue,
      );
      // With no parent context, Frappe sets parent === doc on a top-level form.
      expect(
        DependsOnEvaluator.evaluate("eval:parent.kind == 'X'", {'kind': 'X'}),
        isTrue,
      );
    });

    test('bracket member access and string methods', () {
      expect(
        DependsOnEvaluator.evaluate("eval:doc['a'] == 'X'", {'a': 'X'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a.toLowerCase() == 'x'", {
          'a': 'X',
        }),
        isTrue,
      );
    });
  });

  group('default-on-error is per property', () {
    // An unparseable / unsupported expression must not silently make a field
    // mandatory or read-only. depends_on defaults visible=true; the other two
    // default false.
    const bad =
        'eval:doc.a.map(x => { return x; })'; // statement body: unsupported

    test('depends_on defaults to true (field stays visible)', () {
      expect(DependsOnEvaluator.evaluate(bad, {'a': 1}), isTrue);
    });

    test('mandatory/read_only default to false via evaluate2', () {
      expect(DependsOnEvaluator.evaluate2(bad, {'a': 1}, false), isFalse);
    });

    test('unsupported fn: prefix falls back to the default', () {
      expect(DependsOnEvaluator.evaluate('fn:my_handler', {}), isTrue);
      expect(DependsOnEvaluator.evaluate2('fn:my_handler', {}, false), isFalse);
    });

    test('a JS expression MISSING the eval: prefix stays a key lookup', () {
      // Desk's final else branch is `doc[expression]`, so an admin who forgets
      // the prefix gets a hidden field. Evaluating the text instead would show
      // a field Desk hides.
      expect(DependsOnEvaluator.evaluate("doc.a == 'X'", {'a': 'X'}), isFalse);
    });
  });

  group('referencedFields', () {
    test('extracts single doc.field reference', () {
      expect(
        DependsOnEvaluator.referencedFields(
          'eval:doc.marital_status == "Married"',
        ),
        {'marital_status'},
      );
    });
    test('extracts multiple references across && / ||', () {
      expect(
        DependsOnEvaluator.referencedFields(
          'eval:doc.a == 1 && doc.b != 2 || doc.c',
        ),
        {'a', 'b', 'c'},
      );
    });
    test('extracts from [..].includes(doc.field)', () {
      expect(
        DependsOnEvaluator.referencedFields(
          'eval:["A","B"].includes(doc.kind)',
        ),
        {'kind'},
      );
    });
    test('null/empty -> empty set', () {
      expect(DependsOnEvaluator.referencedFields(null), isEmpty);
      expect(DependsOnEvaluator.referencedFields(''), isEmpty);
    });
    test('bare fieldname (no eval:, no doc.) -> that field', () {
      // Frappe allows depends_on = "field_name" (truthy check).
      expect(DependsOnEvaluator.referencedFields('some_flag'), {'some_flag'});
    });

    test('arrow-fn params are NOT reported as fields', () {
      // Must be {present_season}, never {present_season, season} — a bogus
      // `season` edge would pollute DependencyGraph._findCycles / linkClears.
      expect(
        DependsOnEvaluator.referencedFields(
          'eval:(doc.present_season || []).some(r => r.season == "Kharif")',
        ),
        {'present_season'},
      );
    });

    test('parent.<field> refs are NOT graph edges', () {
      // This set keys the reverse-dependency graph on fields of THIS document.
      // A parent field never appears in the local change stream, so recording
      // it would be a dead edge.
      expect(
        DependsOnEvaluator.referencedFields(
          "eval:doc.a == '1' && parent.b == '2'",
        ),
        {'a'},
      );
      // Referencing only parent fields yields the empty set, which callers
      // read as "subscribe to all changes".
      expect(
        DependsOnEvaluator.referencedFields('eval:parent.istable'),
        isEmpty,
      );
    });

    test('unknown globals evaluate falsy instead of erroring to visible', () {
      // frappe.boot.developer_mode is off in production, so Desk hides these
      // fields; erroring into the depends_on "show it" default would not.
      expect(
        DependsOnEvaluator.evaluate('eval:frappe.boot.developer_mode', {}),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!frappe.boot.developer_mode', {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.name == frappe.session.user', {
          'name': 'X',
        }),
        isFalse,
      );
    });

    test('.length on a non-string/list is undefined, not an error', () {
      // JS: `(1).length` is undefined. Throwing would push
      // `doc.x && doc.x.length` into the depends_on "show it" default.
      const expr = 'eval:doc.restrict_ip && doc.restrict_ip.length';
      expect(DependsOnEvaluator.evaluate(expr, {'restrict_ip': 1}), isFalse);
      expect(
        DependsOnEvaluator.evaluate(expr, {'restrict_ip': '10.0.0.1'}),
        isTrue,
      );
    });

    test(
      'trailing semicolon is tolerated (Frappe wraps in `let out = …;`)',
      () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.pf === "Report";', {
            'pf': 'Report',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.pf === "Report";', {'pf': 'X'}),
          isFalse,
        );
        expect(DependsOnEvaluator.evaluate('eval:true;', {}), isTrue);
      },
    );

    test('numeric-literal membership matches a normalized Int field', () {
      // Verbatim from snf assessment_form.json; assessmnt_no is fieldtype Int,
      // which FieldNormalizer stringifies. Desk holds a real 5 and shows the
      // field, so strict JS membership ("5" not in [5,6]) would hide it AND
      // drop its mandatory_depends_on.
      const expr =
          "eval:doc.attendc_status == 'Present' && [5,6].includes(doc.assessmnt_no)";
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'attendc_status': 'Present',
          'assessmnt_no': '5',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'attendc_status': 'Present',
          'assessmnt_no': 5,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(expr, {
          'attendc_status': 'Present',
          'assessmnt_no': '4',
        }),
        isFalse,
      );
      // in_list gets the same treatment.
      expect(
        DependsOnEvaluator.evaluate('eval:in_list([1,2], doc.n)', {'n': '2'}),
        isTrue,
      );
      // Plain string membership is untouched.
      expect(
        DependsOnEvaluator.evaluate("eval:['A','B'].includes(doc.s)", {
          's': 'C',
        }),
        isFalse,
      );
    });

    test('out-of-form roots are unanalyzable -> empty (subscribe-all)', () {
      // `frappe.*` / `locals` / `cur_frm` reference state outside the form, so
      // the root must NOT be mistaken for a fieldname.
      expect(
        DependsOnEvaluator.referencedFields('eval:frappe.some_fn() > 0'),
        isEmpty,
      );
      expect(
        DependsOnEvaluator.referencedFields('eval:cur_frm.doc.x == 1'),
        isEmpty,
      );
    });

    test('link_filters JSON still yields doc.* refs (regex fallback)', () {
      // DependencyGraph passes DocField.linkFilters here; it is not a JS
      // expression, so the parser fails and the regex fallback must still work.
      expect(
        DependsOnEvaluator.referencedFields(
          '{"district": "eval:doc.state", "block": "eval:doc.district"}',
        ),
        {'state', 'district'},
      );
    });
  });
}
