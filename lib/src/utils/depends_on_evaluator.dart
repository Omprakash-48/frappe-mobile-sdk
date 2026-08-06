// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/foundation.dart';

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
    if (expression == null || expression.isEmpty) return defaultOnError;

    final raw = expression.trim();

    // `fn:` triggers a client script through frm.script_manager. There is no
    // equivalent offline, so defer to the caller's default.
    if (raw.startsWith('fn:')) {
      _logOnce(
        expression,
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
    // A bare `eval:` (or `eval: `) is non-empty, so evaluate2's null/empty guard
    // lets it through. Desk would SyntaxError on `let out = ; return out`, so
    // `true` is not the Desk answer either — and returning it makes a field with
    // `mandatory_depends_on: "eval:"` permanently mandatory with no way to
    // satisfy it, the exact failure mode the per-property defaults avoid.
    if (expr.isEmpty) return defaultOnError;

    try {
      final doc = _evalScope(formData);
      return evalJsExpressionAsBool(expr, {
        'doc': doc,
        // Desk aliases `parent` to `doc` when there is no parent form
        // (`this.frm ? this.frm.doc : this.doc`), so these must be the SAME
        // object: a mutating expression has to see one shared copy, not two.
        'parent': parentData == null ? doc : _evalScope(parentData),
      });
    } on JsEvalException catch (e) {
      _logOnce(
        expression,
        'DependsOnEvaluator: cannot evaluate "$expression" — $e; '
        'defaulting to $defaultOnError',
      );
      return defaultOnError;
    } catch (e, st) {
      _logOnce(
        expression,
        'DependsOnEvaluator: unexpected failure for "$expression" — $e\n$st; '
        'defaulting to $defaultOnError',
      );
      return defaultOnError;
    }
  }

  /// Builds the `doc` / `parent` scope for an `eval:` expression.
  ///
  /// ALWAYS returns a new map — unlike the `_withDefaultDocstatus` this
  /// replaces, which returned [src] itself whenever `docstatus` was present.
  ///
  /// * `docstatus` defaults to 0 when absent. In Frappe a document always has a
  ///   `docstatus` — 0 while it is a draft — so desk expressions like
  ///   `eval:doc.docstatus === 0` are true on a new doc. Form data assembled
  ///   client-side does not always carry the key, and reading it as undefined
  ///   mis-gated every draft-only visibility / mandatory / read-only rule.
  /// * every `List` value is copied one level, because `pop()` mutates its
  ///   receiver and these lists are live child-table state. `_computeUiState`
  ///   runs per field per change, so a mutating expression on the real list
  ///   would delete a row on every keystroke. One level is enough: the only
  ///   mutating method removes an element rather than editing one, so the row
  ///   maps stay shared and are never written to.
  ///
  /// The `...src` spread MUST come first, so the copied lists overwrite the
  /// shared references it inserts. Reordering silently disables the copy.
  static Map<String, dynamic> _evalScope(Map<String, dynamic> src) => {
    ...src,
    if (!src.containsKey('docstatus')) 'docstatus': 0,
    for (final e in src.entries)
      if (e.value is List) e.key: List<dynamic>.of(e.value as List),
  };

  /// Expressions already reported by [_logOnce].
  static final Set<String> _loggedFailures = <String>{};

  /// Report an evaluation failure once per expression per process.
  ///
  /// The expression is static DocType meta, so the failure is deterministic —
  /// but `_computeUiState` runs per field per change, so an unparseable
  /// `depends_on` on a 60-field form otherwise emits a log line (and, in the
  /// generic catch, an interpolated stack trace) on every keystroke.
  static void _logOnce(String expression, String message) {
    if (!_loggedFailures.add(expression)) return;
    // Bounded: DocType meta is finite, but a pathological host could synthesise
    // expressions at runtime, so don't let the set grow without limit.
    if (_loggedFailures.length > 512) _loggedFailures.clear();
    sdkLog(message);
  }

  /// Clears the once-per-expression log gate. Test seam only.
  @visibleForTesting
  static void resetLogGateForTest() => _loggedFailures.clear();

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
    // The whole expression isn't a bare `doc.field` reference (e.g. it's wrapped
    // in a JS call like `(doc.x||'').replace(/.../, '')`). Fall back to the
    // first `doc.<field>` reference anywhere in the string so dependent-field
    // detection — the Link field's "select X first" hint — still works for these
    // more complex link_filters values.
    return RegExp(r'doc\.([A-Za-z_][A-Za-z0-9_]*)').firstMatch(expr)?.group(1);
  }

  static String _extractFieldName(String expr) {
    expr = expr.trim();
    if (expr.startsWith('doc.')) {
      expr = expr.substring(4).trim();
    }
    return expr;
  }
}
