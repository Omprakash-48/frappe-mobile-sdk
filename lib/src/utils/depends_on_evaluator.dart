// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'js_expression.dart';
import 'sdk_log.dart';

/// Evaluates Frappe `depends_on` / `mandatory_depends_on` /
/// `read_only_depends_on` expressions.
///
/// Mirrors `evaluate_depends_on_value` in
/// `frappe/public/js/frappe/form/layout.js`:
///
/// * `eval:<js>` — evaluated as a real JavaScript expression with `doc` and
///   `parent` in scope, via [evalJsExpression]. Frappe uses
///   `new Function(...)` here, so JS truthiness and JS operator semantics
///   apply. Notably `[]` is TRUTHY, and `['A'] == 'A'` is true.
/// * `<fieldname>` — the bare shorthand. Frappe applies a special array rule:
///   `$.isArray(value) ? !!value.length : !!value`. An empty multi-select is
///   therefore falsy in this form but truthy in the `eval:` form.
/// * `fn:<handler>` — a client-script trigger. Not available offline;
///   evaluates to the caller's default.
///
/// **Trust boundary:** expressions come from server-side DocType meta
/// configured by Frappe admins, not from end-user input. [evaluate] parses a
/// restricted grammar (see `js_expression.dart`) rather than executing
/// arbitrary code, but it is not a sandbox for untrusted strings.
class DependsOnEvaluator {
  /// Returns the set of fieldnames an expression references. Used to build the
  /// reverse-dependency graph. Returns an EMPTY set for a non-null, non-empty
  /// expression it cannot parse — callers treat that as "subscribe to all"
  /// (see DependencyGraph fallback). A bare `field_name` (Frappe truthy form)
  /// resolves to {field_name}.
  static Set<String> referencedFields(String? expression) {
    if (expression == null || expression.trim().isEmpty) return const {};
    var expr = expression.trim();
    if (expr.startsWith('eval:')) expr = expr.substring(5).trim();

    // Preferred path: walk the AST, which correctly excludes arrow-function
    // parameters (`r` in `rows.some(r => r.season == "X")`).
    try {
      final refs = jsReferencedFields(expr);
      if (refs.isNotEmpty) return refs;
    } on JsEvalException {
      // Falls through to the token scan below.
    }

    // Fallback token scan. DependencyGraph also passes `link_filters` here,
    // which is JSON rather than a JS expression (e.g.
    // `{"district": "eval:doc.state"}`) and never parses — but its embedded
    // `doc.<field>` references still have to wire up.
    //
    // The lookbehind keeps a qualified root out: in `cur_frm.doc.x` the `doc`
    // is not the form document, so `x` is not one of its fields. `parent.` is
    // excluded for the same reason as in the AST walk — parent fields never
    // appear in this document's change stream.
    final docRefs = RegExp(
      r'(?<![\w.])doc\.(\w+)',
    ).allMatches(expr).map((m) => m.group(1)!).toSet();
    if (docRefs.isNotEmpty) return docRefs;

    // No `doc.` tokens: a bare identifier is the Frappe truthy form.
    final bare = RegExp(r'^(\w+)$').firstMatch(expr);
    if (bare != null) return {bare.group(1)!};

    return const {}; // unparseable -> caller falls back to subscribe-all
  }

  /// Like [evaluate] but returns [defaultWhenEmpty] for a null/empty expression.
  /// `depends_on` defaults visible=true; `mandatory_depends_on` /
  /// `read_only_depends_on` must default false when absent.
  ///
  /// [defaultWhenEmpty] is ALSO the fallback when a non-empty expression fails
  /// to evaluate. Defaulting an unparseable `mandatory_depends_on` to true
  /// would make a field permanently mandatory with no way to satisfy it.
  static bool evaluate2(
    String? expr,
    Map<String, dynamic> data,
    bool defaultWhenEmpty, {
    Map<String, dynamic>? parentData,
  }) => (expr == null || expr.isEmpty)
      ? defaultWhenEmpty
      : evaluate(
          expr,
          data,
          parentData: parentData,
          defaultOnError: defaultWhenEmpty,
        );

  /// Evaluate a `depends_on` expression against [formData].
  ///
  /// [parentData] supplies `parent` for child-row expressions. When omitted,
  /// `parent` aliases `doc` — matching Frappe, where `parent` is
  /// `this.frm ? this.frm.doc : this.doc`.
  ///
  /// Returns [defaultOnError] (true by default, i.e. "show the field") if the
  /// expression falls outside the supported grammar or throws.
  static bool evaluate(
    String? expression,
    Map<String, dynamic> formData, {
    Map<String, dynamic>? parentData,
    bool defaultOnError = true,
  }) {
    if (expression == null || expression.isEmpty) return true;

    final raw = expression.trim();

    // `fn:` triggers a client script through frm.script_manager. There is no
    // equivalent offline, so defer to the caller's default.
    if (raw.startsWith('fn:')) {
      sdkLog(
        'DependsOnEvaluator: "fn:" expressions are not supported offline — '
        'defaulting to $defaultOnError for "$expression"',
      );
      return defaultOnError;
    }

    // Bare (non-`eval:`) shorthand: Frappe's final `else` branch is a plain
    // `doc[expression]` lookup with the array rule
    // `$.isArray(value) ? !!value.length : !!value`. An empty child table /
    // multi-select is therefore falsy here, unlike in the `eval:` form.
    //
    // This deliberately does NOT fall back to evaluating the text as JS. Desk
    // treats `depends_on: "doc.a == 'X'"` (missing prefix) as a lookup of a key
    // literally named `doc.a == 'X'`, finds nothing, and hides the field.
    // Evaluating it would show a field Desk hides — the exact class of
    // divergence this evaluator exists to remove.
    if (!raw.startsWith('eval:')) {
      final value = formData[raw];
      if (value is List) return value.isNotEmpty;
      return jsTruthy(value);
    }

    final expr = raw.substring(5).trim();
    if (expr.isEmpty) return true;

    try {
      final doc = _withDefaultDocstatus(formData);
      return evalJsExpressionAsBool(expr, {
        'doc': doc,
        'parent': parentData == null ? doc : _withDefaultDocstatus(parentData),
      });
    } on JsEvalException catch (e) {
      sdkLog(
        'DependsOnEvaluator: cannot evaluate "$expression" — $e; '
        'defaulting to $defaultOnError',
      );
      return defaultOnError;
    } catch (e, st) {
      sdkLog(
        'DependsOnEvaluator: unexpected failure for "$expression" — $e\n$st; '
        'defaulting to $defaultOnError',
      );
      return defaultOnError;
    }
  }

  /// Supplies `docstatus: 0` when the key is absent.
  ///
  /// In Frappe a document always has a `docstatus` — 0 while it is a draft — so
  /// desk expressions like `eval:doc.docstatus === 0` are true on a new doc.
  /// Form data assembled client-side does not always carry the key, and reading
  /// it as undefined made those expressions false, mis-gating every draft-only
  /// visibility / mandatory / read-only rule.
  ///
  /// Copies only when the key is missing, and never mutates the caller's map —
  /// [formData] is the live form state, not this evaluator's to write to.
  static Map<String, dynamic> _withDefaultDocstatus(
    Map<String, dynamic> formData,
  ) => formData.containsKey('docstatus')
      ? formData
      : {...formData, 'docstatus': 0};

  /// Extract `doc.fieldname` from an eval expression like `eval:doc.x` or
  /// `eval: doc.x`. Returns the field name, or null if the value is not an
  /// `eval:doc` expression.
  ///
  /// Used by `LinkOptionService` to resolve `link_filters` values; kept as a
  /// string operation because those values are single field references, not
  /// general expressions.
  static String? extractEvalDocField(String value) {
    String expr = value.trim();
    if (value.startsWith('eval:')) {
      expr = value.substring(5).trimLeft();
    }
    String fieldName = _extractFieldName(expr);
    if (expr != fieldName) return fieldName;
    // The whole expression isn't a bare `doc.field` reference (e.g. it's
    // wrapped in a JS call like `(doc.x||'').replace(/.../, '')`). Fall back
    // to the first `doc.<field>` reference anywhere in the string so
    // dependent-field detection (used for the link field's "select X first"
    // UX) still works for these more complex link_filters expressions.
    final match = RegExp(r'doc\.([A-Za-z_][A-Za-z0-9_]*)').firstMatch(expr);
    return match?.group(1);
  }

  static String _extractFieldName(String expr) {
    expr = expr.trim();
    if (expr.startsWith('doc.')) {
      expr = expr.substring(4).trim();
    }
    return expr;
  }
}
