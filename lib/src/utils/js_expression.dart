// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

/// A tokenizer + Pratt parser + interpreter for the subset of JavaScript
/// expressions that Frappe `depends_on` / `mandatory_depends_on` /
/// `read_only_depends_on` conditions actually use.
///
/// **Why this exists.** Frappe Desk evaluates an `eval:` condition as real
/// JavaScript — `frappe/public/js/frappe/utils/utils.js` builds
/// `new Function(...names, 'let out = <code>; return out')` and calls it with
/// `{doc, parent}` in scope (see `evaluate_depends_on_value` in
/// `frappe/public/js/frappe/form/layout.js`). Any string-matching
/// approximation diverges the moment an admin writes something outside the
/// matched shapes — `(doc.rows || []).some(r => r.x == "y")`, a compact
/// `doc.a=='X'`, `!doc.flag`, `.length`, a ternary. This evaluates the real
/// grammar instead, so the mobile form agrees with the Desk form.
///
/// **Supported subset** — anything outside it throws [JsEvalException], which
/// callers turn into a per-property default rather than a wrong boolean:
///
/// * literals: numbers, single/double-quoted strings, `true`, `false`,
///   `null`, `undefined`, array literals
/// * identifiers resolved from the evaluation scope (`doc`, `parent`, the
///   Frappe helpers below); any other bare identifier resolves as a field of
///   `doc`, which keeps Frappe's `depends_on: "fieldname"` shorthand working
///   when it is written as `eval:fieldname`
/// * member access `a.b`, `a['b']`, `.length` on lists/strings/maps
/// * method calls from a fixed whitelist ([_listMethods] / [_stringMethods])
/// * single-expression arrow functions: `r => expr`, `(r) => expr`,
///   `(r, i) => expr`
/// * unary `!`, unary `-`/`+`
/// * binary `===`, `!==`, `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`,
///   `+`, `-`, `*`, `/`, `%`
/// * ternary `cond ? a : b`, parenthesised grouping
///
/// **Deliberately unsupported:** statements, assignment, `function`, block
/// arrow bodies, template literals, `new`, regex literals, and `frappe.*` /
/// `locals` / `cur_frm` globals. Those either cannot be answered offline or
/// are not safe to guess at.
///
/// **Trust boundary:** expressions come from server-side DocType meta authored
/// by Frappe admins. There is no `eval` of arbitrary code here — the
/// interpreter only ever walks the node types above — but this is not a
/// sandbox for untrusted end-user input either.
library;

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

/// Thrown for an expression the subset cannot parse or evaluate.
class JsEvalException implements Exception {
  final String message;
  final String? expression;
  const JsEvalException(this.message, [this.expression]);

  @override
  String toString() => expression == null
      ? 'JsEvalException: $message'
      : 'JsEvalException: $message (in "$expression")';
}

/// Sentinel for JS `undefined`, which is distinct from `null` under `===`
/// but loosely equal to it under `==`.
class JsUndefined {
  const JsUndefined._();
  static const instance = JsUndefined._();
  @override
  String toString() => 'undefined';
}

const _undefined = JsUndefined.instance;

/// Stands in for a global the SDK cannot know offline — today only `frappe`
/// (`frappe.boot.developer_mode`, `frappe.session.user`). Any member or method
/// on it yields the sentinel again, and it is falsy and nullish-equal, so
/// `eval:frappe.boot.developer_mode` hides its field exactly as a production
/// Desk (where `developer_mode` is off) does.
class JsUnknownGlobal {
  const JsUnknownGlobal._();
  static const instance = JsUnknownGlobal._();
  @override
  String toString() => 'undefined';
}

const _unknownGlobal = JsUnknownGlobal.instance;

/// True for values that behave like `null`/`undefined` in comparisons.
bool _isNullish(Object? v) =>
    v == null || v is JsUndefined || v is JsUnknownGlobal;

// ─────────────────────────────────────────────────────────────────────────────
// Tokenizer
// ─────────────────────────────────────────────────────────────────────────────

enum _T { num, str, ident, punct, eof }

class _Token {
  final _T type;
  final String value;
  final int pos;
  const _Token(this.type, this.value, this.pos);
  @override
  String toString() => '${type.name}:$value';
}

/// Multi-character operators, longest first so `===` wins over `==` over `=`.
const _operators = <String>[
  '===',
  '!==',
  '==',
  '!=',
  '<=',
  '>=',
  '&&',
  '||',
  '=>',
  '<',
  '>',
  '!',
  '+',
  '-',
  '*',
  '/',
  '%',
  '?',
  ':',
  '.',
  ',',
  '(',
  ')',
  '[',
  ']',
];

List<_Token> _tokenize(String src) {
  final tokens = <_Token>[];
  var i = 0;

  bool isDigit(String c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;
  bool isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 65 && u <= 90) ||
        (u >= 97 && u <= 122) ||
        c == '_' ||
        c == r'$';
  }

  bool isIdentPart(String c) => isIdentStart(c) || isDigit(c);

  while (i < src.length) {
    final c = src[i];

    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      i++;
      continue;
    }

    // String literal — no escape handling beyond \" \' \\ which is all that
    // appears in practice.
    if (c == '"' || c == "'") {
      final quote = c;
      final sb = StringBuffer();
      i++;
      var closed = false;
      while (i < src.length) {
        if (src[i] == r'\' && i + 1 < src.length) {
          sb.write(src[i + 1]);
          i += 2;
          continue;
        }
        if (src[i] == quote) {
          i++;
          closed = true;
          break;
        }
        sb.write(src[i]);
        i++;
      }
      if (!closed) throw JsEvalException('unterminated string literal', src);
      tokens.add(_Token(_T.str, sb.toString(), i));
      continue;
    }

    // Number literal. A leading '.' is only a decimal point when a digit
    // follows; otherwise it is member access (`doc.x`).
    if (isDigit(c) || (c == '.' && i + 1 < src.length && isDigit(src[i + 1]))) {
      final start = i;
      while (i < src.length && (isDigit(src[i]) || src[i] == '.')) {
        i++;
      }
      tokens.add(_Token(_T.num, src.substring(start, i), start));
      continue;
    }

    if (isIdentStart(c)) {
      final start = i;
      while (i < src.length && isIdentPart(src[i])) {
        i++;
      }
      tokens.add(_Token(_T.ident, src.substring(start, i), start));
      continue;
    }

    var matched = false;
    for (final op in _operators) {
      if (i + op.length <= src.length && src.startsWith(op, i)) {
        tokens.add(_Token(_T.punct, op, i));
        i += op.length;
        matched = true;
        break;
      }
    }
    if (!matched) {
      throw JsEvalException('unexpected character "$c" at $i', src);
    }
  }

  tokens.add(_Token(_T.eof, '', src.length));
  return tokens;
}

// ─────────────────────────────────────────────────────────────────────────────
// AST
// ─────────────────────────────────────────────────────────────────────────────

sealed class JsNode {
  const JsNode();
}

class JsLiteral extends JsNode {
  final Object? value;
  const JsLiteral(this.value);
}

class JsIdentifier extends JsNode {
  final String name;
  const JsIdentifier(this.name);
}

class JsArrayLiteral extends JsNode {
  final List<JsNode> elements;
  const JsArrayLiteral(this.elements);
}

class JsMember extends JsNode {
  final JsNode target;

  /// Static property name for `a.b`; null when [computed] carries `a[expr]`.
  final String? property;
  final JsNode? computed;
  const JsMember(this.target, {this.property, this.computed});
}

class JsCall extends JsNode {
  /// Method call receiver — null for a plain global call like `in_list(...)`.
  final JsNode? receiver;
  final String name;
  final List<JsNode> args;
  const JsCall(this.receiver, this.name, this.args);
}

class JsUnary extends JsNode {
  final String op;
  final JsNode operand;
  const JsUnary(this.op, this.operand);
}

class JsBinary extends JsNode {
  final String op;
  final JsNode left;
  final JsNode right;
  const JsBinary(this.op, this.left, this.right);
}

class JsConditional extends JsNode {
  final JsNode test;
  final JsNode consequent;
  final JsNode alternate;
  const JsConditional(this.test, this.consequent, this.alternate);
}

class JsArrow extends JsNode {
  final List<String> params;
  final JsNode body;
  const JsArrow(this.params, this.body);
}

// ─────────────────────────────────────────────────────────────────────────────
// Parser (precedence climbing)
// ─────────────────────────────────────────────────────────────────────────────

/// Binary precedence, higher binds tighter. Mirrors JS.
const _precedence = <String, int>{
  '||': 1,
  '&&': 2,
  '==': 3,
  '!=': 3,
  '===': 3,
  '!==': 3,
  '<': 4,
  '>': 4,
  '<=': 4,
  '>=': 4,
  '+': 5,
  '-': 5,
  '*': 6,
  '/': 6,
  '%': 6,
};

class _Parser {
  final List<_Token> _tokens;
  final String _src;
  int _i = 0;

  _Parser(this._tokens, this._src);

  _Token get _cur => _tokens[_i];

  bool _isPunct(String v) => _cur.type == _T.punct && _cur.value == v;

  void _expect(String v) {
    if (!_isPunct(v)) {
      throw JsEvalException('expected "$v" but found "${_cur.value}"', _src);
    }
    _i++;
  }

  JsNode parse() {
    final node = _parseExpression();
    if (_cur.type != _T.eof) {
      throw JsEvalException('unexpected trailing "${_cur.value}"', _src);
    }
    return node;
  }

  JsNode _parseExpression() => _parseConditional();

  JsNode _parseConditional() {
    final test = _parseBinary(0);
    if (!_isPunct('?')) return test;
    _i++;
    final consequent = _parseExpression();
    _expect(':');
    final alternate = _parseExpression();
    return JsConditional(test, consequent, alternate);
  }

  JsNode _parseBinary(int minPrec) {
    var left = _parseUnary();
    while (true) {
      if (_cur.type != _T.punct) break;
      final prec = _precedence[_cur.value];
      if (prec == null || prec < minPrec) break;
      final op = _cur.value;
      _i++;
      // All supported binary operators are left-associative.
      final right = _parseBinary(prec + 1);
      left = JsBinary(op, left, right);
    }
    return left;
  }

  JsNode _parseUnary() {
    if (_cur.type == _T.punct &&
        (_cur.value == '!' || _cur.value == '-' || _cur.value == '+')) {
      final op = _cur.value;
      _i++;
      return JsUnary(op, _parseUnary());
    }
    return _parsePostfix();
  }

  /// Primary expression followed by any chain of `.x`, `[x]`, `(...)`.
  JsNode _parsePostfix() {
    var node = _parsePrimary();
    while (true) {
      if (_isPunct('.')) {
        _i++;
        if (_cur.type != _T.ident) {
          throw JsEvalException(
            'expected property name after "." but found "${_cur.value}"',
            _src,
          );
        }
        final name = _cur.value;
        _i++;
        if (_isPunct('(')) {
          node = JsCall(node, name, _parseArgs());
        } else {
          node = JsMember(node, property: name);
        }
        continue;
      }
      if (_isPunct('[')) {
        _i++;
        final idx = _parseExpression();
        _expect(']');
        node = JsMember(node, computed: idx);
        continue;
      }
      if (_isPunct('(')) {
        // Calling a non-member expression, e.g. `(fn)(x)` — not in the subset.
        throw JsEvalException('unsupported call expression', _src);
      }
      break;
    }
    return node;
  }

  List<JsNode> _parseArgs() {
    _expect('(');
    final args = <JsNode>[];
    if (_isPunct(')')) {
      _i++;
      return args;
    }
    while (true) {
      args.add(_parseExpression());
      if (_isPunct(',')) {
        _i++;
        continue;
      }
      _expect(')');
      break;
    }
    return args;
  }

  JsNode _parsePrimary() {
    final t = _cur;

    if (t.type == _T.num) {
      _i++;
      final n = num.tryParse(t.value);
      if (n == null) throw JsEvalException('bad number "${t.value}"', _src);
      return JsLiteral(n);
    }

    if (t.type == _T.str) {
      _i++;
      return JsLiteral(t.value);
    }

    if (t.type == _T.ident) {
      // Single-param arrow without parens: `r => expr`
      if (_tokens[_i + 1].type == _T.punct && _tokens[_i + 1].value == '=>') {
        final param = t.value;
        _i += 2;
        return JsArrow([param], _parseExpression());
      }
      _i++;
      switch (t.value) {
        case 'true':
          return const JsLiteral(true);
        case 'false':
          return const JsLiteral(false);
        case 'null':
          return const JsLiteral(null);
        case 'undefined':
          return const JsLiteral(_undefined);
      }
      // A bare global call like `in_list(...)` / `cint(...)`.
      if (_isPunct('(')) {
        return JsCall(null, t.value, _parseArgs());
      }
      return JsIdentifier(t.value);
    }

    if (_isPunct('[')) {
      _i++;
      final elements = <JsNode>[];
      if (_isPunct(']')) {
        _i++;
        return JsArrayLiteral(elements);
      }
      while (true) {
        elements.add(_parseExpression());
        if (_isPunct(',')) {
          _i++;
          continue;
        }
        _expect(']');
        break;
      }
      return JsArrayLiteral(elements);
    }

    if (_isPunct('(')) {
      // Either a parenthesised arrow parameter list or a grouping. Look ahead
      // for `) =>` to tell them apart without backtracking the whole parse.
      final arrow = _tryParseParenArrow();
      if (arrow != null) return arrow;
      _i++;
      final inner = _parseExpression();
      _expect(')');
      return inner;
    }

    throw JsEvalException('unexpected token "${t.value}"', _src);
  }

  /// At a `(`: if the parens hold only identifiers and are followed by `=>`,
  /// consume them as an arrow function. Otherwise leave the cursor untouched.
  JsArrow? _tryParseParenArrow() {
    var j = _i + 1;
    final params = <String>[];
    if (_tokens[j].type == _T.punct && _tokens[j].value == ')') {
      j++;
    } else {
      while (true) {
        if (_tokens[j].type != _T.ident) return null;
        params.add(_tokens[j].value);
        j++;
        if (_tokens[j].type == _T.punct && _tokens[j].value == ',') {
          j++;
          continue;
        }
        if (_tokens[j].type == _T.punct && _tokens[j].value == ')') {
          j++;
          break;
        }
        return null;
      }
    }
    if (!(_tokens[j].type == _T.punct && _tokens[j].value == '=>')) return null;
    _i = j + 1;
    return JsArrow(params, _parseExpression());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Interpreter
// ─────────────────────────────────────────────────────────────────────────────

/// A resolved arrow function, produced when an arrow node is evaluated.
class _Closure {
  final List<String> params;
  final JsNode body;
  final Map<String, Object?> scope;
  const _Closure(this.params, this.body, this.scope);
}

const _listMethods = <String>{
  'includes',
  'indexOf',
  'some',
  'every',
  'filter',
  'map',
  'join',
  'find',
  'length',
};

const _stringMethods = <String>{
  'includes',
  'indexOf',
  'trim',
  'toLowerCase',
  'toUpperCase',
  'startsWith',
  'endsWith',
  'split',
  'length',
};

/// Frappe JS globals that appear in real `depends_on` conditions.
const _globalFns = <String>{'in_list', 'cint', 'flt', 'cstr', 'Boolean'};

class JsInterpreter {
  final Map<String, Object?> _rootScope;
  final String _src;

  JsInterpreter(this._rootScope, this._src);

  Object? eval(JsNode node) => _eval(node, _rootScope);

  Object? _eval(JsNode node, Map<String, Object?> scope) {
    switch (node) {
      case JsLiteral(:final value):
        return value;

      case JsArrayLiteral(:final elements):
        return elements.map((e) => _eval(e, scope)).toList();

      case JsArrow(:final params, :final body):
        return _Closure(params, body, scope);

      case JsIdentifier(:final name):
        if (scope.containsKey(name)) return scope[name];
        // Globals the SDK cannot resolve offline. Yielding a falsy sentinel
        // matches a production Desk (developer_mode off) and preserves the
        // pre-parser behaviour, instead of erroring into the "show it" default.
        if (name == 'frappe' || name == 'cur_frm' || name == 'locals') {
          return _unknownGlobal;
        }
        // Frappe's `depends_on: "fieldname"` shorthand, written as
        // `eval:fieldname`: resolve against `doc` rather than throwing.
        final doc = _rootScope['doc'];
        if (doc is Map && doc.containsKey(name)) return doc[name];
        return _undefined;

      case JsUnary(:final op, :final operand):
        final v = _eval(operand, scope);
        switch (op) {
          case '!':
            return !truthy(v);
          case '-':
            final n = _toNumber(v);
            return n.isNaN ? double.nan : -n;
          case '+':
            return _toNumber(v);
        }
        throw JsEvalException('unsupported unary "$op"', _src);

      case JsBinary(:final op, :final left, :final right):
        // Short-circuit operators return the OPERAND, not a bool — this is
        // what makes `(doc.rows || [])` yield an empty list.
        if (op == '&&') {
          final l = _eval(left, scope);
          return truthy(l) ? _eval(right, scope) : l;
        }
        if (op == '||') {
          final l = _eval(left, scope);
          return truthy(l) ? l : _eval(right, scope);
        }
        return _binary(op, _eval(left, scope), _eval(right, scope));

      case JsConditional(:final test, :final consequent, :final alternate):
        return truthy(_eval(test, scope))
            ? _eval(consequent, scope)
            : _eval(alternate, scope);

      case JsMember(:final target, :final property, :final computed):
        final obj = _eval(target, scope);
        final key = property ?? _toStringJs(_eval(computed!, scope));
        return _member(obj, key);

      case JsCall(:final receiver, :final name, :final args):
        final argv = args.map((a) => _eval(a, scope)).toList();
        if (receiver == null) return _globalCall(name, argv);
        return _method(_eval(receiver, scope), name, argv, scope);
    }
  }

  // ── property access ───────────────────────────────────────────────────────

  Object? _member(Object? obj, String key) {
    // Chained access on an unknown global stays unknown: `frappe.boot.x`.
    if (obj is JsUnknownGlobal) return _unknownGlobal;
    if (obj == null || obj is JsUndefined) {
      throw JsEvalException('cannot read "$key" of ${obj ?? 'null'}', _src);
    }
    if (key == 'length') {
      if (obj is List) return obj.length;
      if (obj is String) return obj.length;
      // JS: `(1).length` is undefined, not an error. Throwing here would send
      // `doc.x && doc.x.length` into the "show it" default instead of falsy.
      return _undefined;
    }
    if (obj is Map) {
      // Absent key is `undefined`, mirroring JS — not an error.
      return obj.containsKey(key) ? obj[key] : _undefined;
    }
    if (obj is List) {
      final idx = int.tryParse(key);
      if (idx != null) {
        return (idx >= 0 && idx < obj.length) ? obj[idx] : _undefined;
      }
    }
    throw JsEvalException(
      'unsupported property "$key" on ${obj.runtimeType}',
      _src,
    );
  }

  // ── calls ─────────────────────────────────────────────────────────────────

  Object? _globalCall(String name, List<Object?> argv) {
    switch (name) {
      case 'in_list':
        // frappe.utils: in_list(list, item) -> list.includes(item)
        if (argv.length != 2) {
          throw JsEvalException('in_list expects 2 arguments', _src);
        }
        final list = argv[0];
        if (list is! List) return false;
        return list.any((e) => _membershipEquals(e, argv[1]));
      case 'cint':
        if (argv.isEmpty) return 0;
        final n = _toNumber(argv[0]);
        return n.isNaN ? 0 : n.truncate();
      case 'flt':
        if (argv.isEmpty) return 0.0;
        final n = _toNumber(argv[0]);
        return n.isNaN ? 0.0 : n.toDouble();
      case 'cstr':
        if (argv.isEmpty) return '';
        final v = argv[0];
        if (_isNullish(v)) return '';
        return _toStringJs(v);
      case 'Boolean':
        return argv.isNotEmpty && truthy(argv[0]);
    }
    throw JsEvalException('unsupported function "$name"', _src);
  }

  Object? _method(
    Object? recv,
    String name,
    List<Object?> argv,
    Map<String, Object?> scope,
  ) {
    if (recv is JsUnknownGlobal) return _unknownGlobal;
    if (recv == null || recv is JsUndefined) {
      throw JsEvalException('cannot call "$name" of ${recv ?? 'null'}', _src);
    }

    if (recv is List) {
      if (!_listMethods.contains(name)) {
        throw JsEvalException('unsupported array method "$name"', _src);
      }
      switch (name) {
        case 'includes':
          final needle = argv.isEmpty ? _undefined : argv[0];
          return recv.any((e) => _membershipEquals(e, needle));
        case 'indexOf':
          final needle = argv.isEmpty ? _undefined : argv[0];
          return recv.indexWhere((e) => _membershipEquals(e, needle));
        case 'join':
          final sep = argv.isEmpty ? ',' : _toStringJs(argv[0]);
          return recv.map(_toStringJs).join(sep);
        case 'some':
          final fn = _asClosure(argv, name);
          for (var i = 0; i < recv.length; i++) {
            if (truthy(_invoke(fn, [recv[i], i, recv]))) return true;
          }
          return false;
        case 'every':
          final fn = _asClosure(argv, name);
          for (var i = 0; i < recv.length; i++) {
            if (!truthy(_invoke(fn, [recv[i], i, recv]))) return false;
          }
          return true;
        case 'filter':
          final fn = _asClosure(argv, name);
          final out = <Object?>[];
          for (var i = 0; i < recv.length; i++) {
            if (truthy(_invoke(fn, [recv[i], i, recv]))) out.add(recv[i]);
          }
          return out;
        case 'map':
          final fn = _asClosure(argv, name);
          return [
            for (var i = 0; i < recv.length; i++)
              _invoke(fn, [recv[i], i, recv]),
          ];
        case 'find':
          final fn = _asClosure(argv, name);
          for (var i = 0; i < recv.length; i++) {
            if (truthy(_invoke(fn, [recv[i], i, recv]))) return recv[i];
          }
          return _undefined;
      }
    }

    if (recv is String) {
      if (!_stringMethods.contains(name)) {
        throw JsEvalException('unsupported string method "$name"', _src);
      }
      switch (name) {
        case 'includes':
          return recv.contains(_toStringJs(argv.isEmpty ? '' : argv[0]));
        case 'indexOf':
          return recv.indexOf(_toStringJs(argv.isEmpty ? '' : argv[0]));
        case 'trim':
          return recv.trim();
        case 'toLowerCase':
          return recv.toLowerCase();
        case 'toUpperCase':
          return recv.toUpperCase();
        case 'startsWith':
          return recv.startsWith(_toStringJs(argv.isEmpty ? '' : argv[0]));
        case 'endsWith':
          return recv.endsWith(_toStringJs(argv.isEmpty ? '' : argv[0]));
        case 'split':
          return recv.split(_toStringJs(argv.isEmpty ? '' : argv[0]));
      }
    }

    throw JsEvalException(
      'unsupported method "$name" on ${recv.runtimeType}',
      _src,
    );
  }

  _Closure _asClosure(List<Object?> argv, String method) {
    if (argv.isEmpty || argv.first is! _Closure) {
      throw JsEvalException('$method expects an arrow-function argument', _src);
    }
    return argv.first as _Closure;
  }

  Object? _invoke(_Closure fn, List<Object?> args) {
    final scope = Map<String, Object?>.from(fn.scope);
    for (var i = 0; i < fn.params.length; i++) {
      scope[fn.params[i]] = i < args.length ? args[i] : _undefined;
    }
    return _eval(fn.body, scope);
  }

  // ── operators ─────────────────────────────────────────────────────────────

  Object? _binary(String op, Object? l, Object? r) {
    switch (op) {
      case '===':
        return _strictEquals(l, r);
      case '!==':
        return !_strictEquals(l, r);
      case '==':
        return _looseEquals(l, r);
      case '!=':
        return !_looseEquals(l, r);
      case '<':
      case '>':
      case '<=':
      case '>=':
        return _relational(op, l, r);
      case '+':
        // JS `+`: string concatenation if either side is a string primitive.
        final lp = _toPrimitive(l);
        final rp = _toPrimitive(r);
        if (lp is String || rp is String) {
          return _toStringJs(lp) + _toStringJs(rp);
        }
        return _numResult(_toNumber(lp) + _toNumber(rp));
      case '-':
        return _numResult(_toNumber(l) - _toNumber(r));
      case '*':
        return _numResult(_toNumber(l) * _toNumber(r));
      case '/':
        return _numResult(_toNumber(l) / _toNumber(r));
      case '%':
        final a = _toNumber(l);
        final b = _toNumber(r);
        if (a.isNaN || b.isNaN || b == 0) return double.nan;
        return _numResult(a.remainder(b));
    }
    throw JsEvalException('unsupported operator "$op"', _src);
  }

  /// NaN propagates rather than throwing, matching JS arithmetic.
  Object _numResult(num v) => v;

  bool _relational(String op, Object? l, Object? r) {
    final lp = _toPrimitive(l);
    final rp = _toPrimitive(r);
    // JS compares two string operands lexicographically — but `FieldNormalizer`
    // stringifies Int/Float/Currency/Percent, so a field-vs-field comparison of
    // two numeric fields arrives here as two strings where Desk would have had
    // two numbers. `doc.qty > doc.max_qty` with "10" vs "9" must be true, not
    // false. So only compare lexicographically when at least one side is NOT
    // numeric text; otherwise fall through to the numeric path below.
    if (lp is String && rp is String) {
      final ln = num.tryParse(lp.trim());
      final rn = num.tryParse(rp.trim());
      if (ln == null || rn == null) {
        final c = lp.compareTo(rp);
        switch (op) {
          case '<':
            return c < 0;
          case '>':
            return c > 0;
          case '<=':
            return c <= 0;
          case '>=':
            return c >= 0;
        }
      }
    }
    final a = _toNumber(lp);
    final b = _toNumber(rp);
    // Any NaN operand makes every relational comparison false.
    if (a.isNaN || b.isNaN) return false;
    switch (op) {
      case '<':
        return a < b;
      case '>':
        return a > b;
      case '<=':
        return a <= b;
      case '>=':
        return a >= b;
    }
    return false;
  }

  /// Membership equality for `includes` / `indexOf` / `in_list`.
  ///
  /// Strict equality, plus number↔numeric-string equivalence. `FieldNormalizer`
  /// stringifies Int/Float/Currency/Percent, so `[5,6].includes(doc.assessmnt_no)`
  /// on a real Int field arrives as `[5,6].includes('5')`, which strict JS says
  /// is false while Desk (holding a real 5) says true. Same reasoning as the
  /// relational operators — the SDK's own normalization, not JS, is the source
  /// of the mismatch.
  static bool _membershipEquals(Object? a, Object? b) {
    if (_strictEquals(a, b)) return true;
    final aNum = a is num ? a : (a is String ? num.tryParse(a.trim()) : null);
    final bNum = b is num ? b : (b is String ? num.tryParse(b.trim()) : null);
    if (aNum == null || bNum == null) return false;
    // Only bridge the number/numeric-string gap, never string↔string.
    if (a is String && b is String) return false;
    return aNum == bNum;
  }

  static bool _strictEquals(Object? a, Object? b) {
    // An unknown global equals nothing. It is falsy (so
    // `eval:frappe.boot.developer_mode` hides its field), but treating it as
    // nullish here would make `doc.name == frappe.session.user` true whenever
    // `name` is absent — Desk holds a real user string and says false.
    if (a is JsUnknownGlobal || b is JsUnknownGlobal) return false;
    final aNullish = _isNullish(a);
    final bNullish = _isNullish(b);
    if (aNullish || bNullish) {
      // null === null and undefined === undefined, but null !== undefined.
      if (aNullish && bNullish) {
        return (a == null) == (b == null);
      }
      return false;
    }
    if (a is num && b is num) return a == b;
    if (a is String && b is String) return a == b;
    if (a is bool && b is bool) return a == b;
    // Objects/arrays compare by identity in JS.
    if (a is List && b is List) return identical(a, b);
    if (a is Map && b is Map) return identical(a, b);
    return false;
  }

  /// JS abstract (loose) equality, restricted to the value shapes that reach
  /// form data. Notably `['A'] == 'A'` is true because an array's primitive
  /// value is `join(',')`.
  static bool _looseEquals(Object? a, Object? b) {
    if (a is JsUnknownGlobal || b is JsUnknownGlobal) return false;
    final aNullish = _isNullish(a);
    final bNullish = _isNullish(b);
    // null == undefined, and neither equals anything else.
    if (aNullish || bNullish) return aNullish && bNullish;

    if (a is bool || b is bool) {
      // Booleans coerce to 0/1 before comparing.
      final an = _toNumberStatic(a);
      final bn = _toNumberStatic(b);
      if (an.isNaN || bn.isNaN) return false;
      return an == bn;
    }

    final ap = _toPrimitiveStatic(a);
    final bp = _toPrimitiveStatic(b);

    if (ap is String && bp is String) return ap == bp;
    if (ap is num && bp is num) return ap == bp;

    // Mixed string/number: compare numerically, as JS does.
    final an = _toNumberStatic(ap);
    final bn = _toNumberStatic(bp);
    if (an.isNaN || bn.isNaN) return false;
    return an == bn;
  }

  // ── coercions ─────────────────────────────────────────────────────────────

  Object? _toPrimitive(Object? v) => _toPrimitiveStatic(v);
  num _toNumber(Object? v) => _toNumberStatic(v);
  String _toStringJs(Object? v) => _toStringJsStatic(v);

  /// `Array.prototype.toString` is `join(',')`; other values pass through.
  static Object? _toPrimitiveStatic(Object? v) {
    if (v is List) return v.map(_toStringJsStatic).join(',');
    if (v is Map) return '[object Object]';
    return v;
  }

  static num _toNumberStatic(Object? v) {
    if (v is num) return v;
    if (v is bool) return v ? 1 : 0;
    if (v == null) return 0; // Number(null) === 0
    if (v is JsUndefined || v is JsUnknownGlobal) return double.nan;
    if (v is String) {
      final t = v.trim();
      if (t.isEmpty) return 0; // Number('') === 0
      return num.tryParse(t) ?? double.nan;
    }
    if (v is List || v is Map) return _toNumberStatic(_toPrimitiveStatic(v));
    return double.nan;
  }

  static String _toStringJsStatic(Object? v) {
    if (v == null) return 'null';
    if (v is JsUndefined || v is JsUnknownGlobal) return 'undefined';
    if (v is String) return v;
    if (v is bool) return v ? 'true' : 'false';
    if (v is num) {
      if (v.isNaN) return 'NaN';
      // JS prints integral doubles without a trailing ".0".
      if (v is double && v == v.truncateToDouble() && v.isFinite) {
        return v.toInt().toString();
      }
      return v.toString();
    }
    if (v is List) return v.map(_toStringJsStatic).join(',');
    if (v is Map) return '[object Object]';
    return v.toString();
  }

  /// JS truthiness. Falsy: `null`, `undefined`, `false`, `0`, `NaN`, `''`.
  /// Everything else — including `[]` and `{}` — is truthy.
  static bool truthy(Object? v) {
    if (_isNullish(v)) return false;
    if (v is bool) return v;
    if (v is num) return v != 0 && !v.isNaN;
    if (v is String) return v.isNotEmpty;
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry points
// ─────────────────────────────────────────────────────────────────────────────

/// Parsed-AST cache. Frappe caches compiled expression functions the same way
/// (`eval_function_cache` in `frappe/public/js/frappe/utils/utils.js`); the
/// evaluator runs per field per change, so re-tokenizing on every keystroke of
/// a large form is a measurable cost.
final Map<String, JsNode> _astCache = {};
const _astCacheLimit = 512;

/// Parse [source] into an AST, memoised by source text.
/// Throws [JsEvalException] if it falls outside the supported subset.
JsNode parseJsExpression(String source) {
  final cached = _astCache[source];
  if (cached != null) return cached;
  // Frappe wraps the condition as `let out = <code>; return out`, so a trailing
  // `;` (e.g. `eval:doc.x === "Report";`) is valid there and must not fail here.
  var src = source.trimRight();
  while (src.endsWith(';')) {
    src = src.substring(0, src.length - 1).trimRight();
  }
  final ast = _Parser(_tokenize(src), src).parse();
  if (_astCache.length >= _astCacheLimit) _astCache.clear();
  _astCache[source] = ast;
  return ast;
}

/// Evaluate [source] against [scope] and return the raw JS value.
/// Throws [JsEvalException] for anything unsupported.
Object? evalJsExpression(String source, Map<String, Object?> scope) =>
    JsInterpreter(scope, source).eval(parseJsExpression(source));

/// Evaluate [source] and apply JS truthiness to the result.
bool evalJsExpressionAsBool(String source, Map<String, Object?> scope) =>
    JsInterpreter.truthy(evalJsExpression(source, scope));

/// JS truthiness, exposed for callers that already hold a value.
bool jsTruthy(Object? value) => JsInterpreter.truthy(value);

/// Fieldnames reachable through `doc.` / `parent.` in [source].
///
/// Walks the AST so arrow-function parameters and their members are excluded:
/// `(doc.rows || []).some(r => r.season == "X")` yields `{rows}`, never
/// `{rows, season}`. A bogus `season` edge would pollute the reverse-dependency
/// graph and its cycle detection.
/// Rejects a member/call whose root is an identifier other than `doc` /
/// `parent` / an arrow parameter — e.g. `frappe.some_fn()`, `locals.x`,
/// `cur_frm.doc`. Those reference state outside the form, so the dependency
/// set cannot be determined and the caller must fall back to subscribe-all
/// rather than mistaking the root for a fieldname.
void _requireAnalyzableRoot(JsNode root, Set<String> bound, String source) {
  if (root is! JsIdentifier) return;
  if (root.name == 'doc' || root.name == 'parent') return;
  if (bound.contains(root.name)) return;
  throw JsEvalException(
    'cannot determine dependencies through "${root.name}"',
    source,
  );
}

Set<String> jsReferencedFields(String source) {
  final ast = parseJsExpression(source);
  final out = <String>{};

  void walk(JsNode node, Set<String> bound) {
    switch (node) {
      case JsLiteral():
        return;

      case JsIdentifier(:final name):
        // A bare identifier that is not an arrow param and not a scope root
        // is Frappe's `eval:fieldname` shorthand.
        if (!bound.contains(name) &&
            name != 'doc' &&
            name != 'parent' &&
            !_globalFns.contains(name)) {
          out.add(name);
        }

      case JsArrayLiteral(:final elements):
        for (final e in elements) {
          walk(e, bound);
        }

      case JsArrow(:final params, :final body):
        walk(body, {...bound, ...params});

      case JsUnary(:final operand):
        walk(operand, bound);

      case JsBinary(:final left, :final right):
        walk(left, bound);
        walk(right, bound);

      case JsConditional(:final test, :final consequent, :final alternate):
        walk(test, bound);
        walk(consequent, bound);
        walk(alternate, bound);

      case JsMember(:final target, :final property, :final computed):
        // `doc.x` -> x. Anything else recurses without recording, so
        // `r.season` (r bound by an arrow) contributes nothing.
        //
        // `parent.x` is deliberately NOT recorded: this set drives the
        // reverse-dependency graph, which is keyed on fields of THIS document.
        // A parent field never appears in the local change stream, so recording
        // it would create a dead edge and — for an expression that references
        // only parent fields — rob the owner of the empty-set subscribe-all
        // fallback it needs.
        if (property != null &&
            target is JsIdentifier &&
            !bound.contains(target.name)) {
          if (target.name == 'doc') {
            out.add(property);
            return;
          }
          if (target.name == 'parent') return;
        }
        _requireAnalyzableRoot(target, bound, source);
        walk(target, bound);
        if (computed != null) walk(computed, bound);

      case JsCall(:final receiver, :final args):
        if (receiver != null) {
          _requireAnalyzableRoot(receiver, bound, source);
          walk(receiver, bound);
        }
        for (final a in args) {
          walk(a, bound);
        }
    }
  }

  walk(ast, const {});
  return out;
}
