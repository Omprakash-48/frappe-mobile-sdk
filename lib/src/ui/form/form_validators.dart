/// Returns an error string, or null if valid. Runs against the full form data.
typedef FieldValidator =
    String? Function(dynamic value, Map<String, dynamic> formData);

/// Async variant (server / duplicate checks). Awaited by validateAsync().
typedef AsyncFieldValidator =
    Future<String?> Function(dynamic value, Map<String, dynamic> formData);

/// Returns a map of fieldname -> error (or null) for cross-field rules.
typedef CrossFieldValidator =
    Map<String, String?>? Function(Map<String, dynamic> formData);
