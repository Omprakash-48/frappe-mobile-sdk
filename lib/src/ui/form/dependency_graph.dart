import '../../models/doc_type_meta.dart';
import '../../utils/depends_on_evaluator.dart';

/// Reverse-dependency graph: changedField -> fields that must refresh.
/// Built once from DocTypeMeta. See the form state-management design spec.
class DependencyGraph {
  final Map<String, Set<String>>
  _uiDependents; // A -> fields whose uiState recomputes
  final Map<String, Set<String>>
  _fetchTargets; // A -> fields with fetch_from "A.x"
  final Map<String, Set<String>>
  _linkClears; // A -> dependent Link fields to clear
  final Set<String> _fallbackAll; // fields that refresh on ANY change
  final List<List<String>> _valueCycles;

  DependencyGraph._(
    this._uiDependents,
    this._fetchTargets,
    this._linkClears,
    this._fallbackAll,
    this._valueCycles,
  );

  Set<String> affectedBy(String changed) => {
    ...?_uiDependents[changed],
    ...?_fetchTargets[changed],
    ...?_linkClears[changed],
    ..._fallbackAll,
  };

  Set<String> fetchTargetsOf(String changed) => {...?_fetchTargets[changed]};
  Set<String> linkClearsOf(String changed) => {...?_linkClears[changed]};
  List<List<String>> get valueCycles => _valueCycles;

  void assertNoValueCycles() {
    assert(
      _valueCycles.isEmpty,
      'Value-propagation cycle(s) in form meta: $_valueCycles',
    );
  }

  static DependencyGraph build(DocTypeMeta meta) {
    final ui = <String, Set<String>>{};
    final fetch = <String, Set<String>>{};
    final clear = <String, Set<String>>{};
    final fallback = <String>{};
    // directed value edges (source -> target) for cycle detection
    final valueEdges = <String, Set<String>>{};

    void addUi(String src, String dst) => (ui[src] ??= {}).add(dst);
    void addFetch(String src, String dst) {
      (fetch[src] ??= {}).add(dst);
      (valueEdges[src] ??= {}).add(dst);
    }

    void addClear(String src, String dst) {
      (clear[src] ??= {}).add(dst);
      (valueEdges[src] ??= {}).add(dst);
    }

    void wireUiExpr(String? expr, String owner) {
      if (expr == null || expr.isEmpty) return;
      final refs = DependsOnEvaluator.referencedFields(expr);
      if (refs.isEmpty) {
        fallback.add(owner); // present but unparseable -> subscribe-all
        return;
      }
      for (final src in refs) {
        addUi(src, owner);
      }
    }

    for (final f in meta.fields) {
      final name = f.fieldname;
      if (name == null || name.isEmpty) continue;

      wireUiExpr(f.dependsOn, name);
      wireUiExpr(f.mandatoryDependsOn, name);
      wireUiExpr(f.readOnlyDependsOn, name);

      final ff = f.fetchFrom;
      if (ff != null && ff.contains('.')) {
        final src = ff.split('.').first.trim();
        if (src.isNotEmpty) addFetch(src, name);
      }

      final lf = f.linkFilters;
      if (lf != null && lf.isNotEmpty) {
        for (final src in DependsOnEvaluator.referencedFields(lf)) {
          addClear(src, name);
        }
      }
    }

    final cycles = _findCycles(valueEdges);
    return DependencyGraph._(ui, fetch, clear, fallback, cycles);
  }

  /// DFS cycle detection over directed value edges. Returns each cycle as the
  /// ordered list of nodes. Used to fail-fast on fetch_from/link oscillation.
  static List<List<String>> _findCycles(Map<String, Set<String>> edges) {
    final cycles = <List<String>>[];
    final visited = <String>{};
    final stack = <String>[];
    final onStack = <String>{};

    void dfs(String node) {
      visited.add(node);
      stack.add(node);
      onStack.add(node);
      for (final next in edges[node] ?? const <String>{}) {
        if (!visited.contains(next)) {
          dfs(next);
        } else if (onStack.contains(next)) {
          final i = stack.indexOf(next);
          cycles.add(stack.sublist(i).toList());
        }
      }
      stack.removeLast();
      onStack.remove(node);
    }

    for (final node in edges.keys) {
      if (!visited.contains(node)) dfs(node);
    }
    return cycles;
  }
}
