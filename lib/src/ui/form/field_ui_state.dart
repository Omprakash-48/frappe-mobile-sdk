/// Per-field derived UI state. Recomputed only when a dependency changes.
class FieldUiState {
  final bool visible;
  final bool required;
  final bool readOnly;
  const FieldUiState({
    this.visible = true,
    this.required = false,
    this.readOnly = false,
  });

  /// Shared instance for static fields (no depends_on/mandatory/readonly) so
  /// they need no per-field notifier (cost scales with dynamic fields).
  static const editable = FieldUiState();

  @override
  bool operator ==(Object other) =>
      other is FieldUiState &&
      other.visible == visible &&
      other.required == required &&
      other.readOnly == readOnly;

  @override
  int get hashCode => Object.hash(visible, required, readOnly);
}
