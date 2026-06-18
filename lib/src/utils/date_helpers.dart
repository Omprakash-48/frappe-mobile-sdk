/// Coerces a dynamic value into a [DateTime] or null.
/// - `null` → null
/// - `DateTime` → returned as-is
/// - `String` → parsed via [DateTime.tryParse]; null on parse failure
/// - any other type → null
///
/// Shared by the date and datetime field widgets and by the form builder's
/// patched-value normalizer so the coercion logic lives in one place.
DateTime? parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Formats a duration expressed in seconds as `HH:MM:SS` (when hours > 0)
/// or `MM:SS`. Each component is zero-padded to two digits. Shared by the
/// Duration field widget and the form builder's patched-value formatter.
String formatDurationSeconds(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${secs.toString().padLeft(2, '0')}';
}
