typedef TranslateFn = String Function(String source, [List<Object>? args]);

class FrappeTranslations {
  static TranslateFn? _delegate;

  static void setDelegate(TranslateFn delegate) {
    _delegate = delegate;
  }

  static String translate(String source, [List<Object>? args]) {
    if (_delegate != null) {
      return _delegate!(source, args);
    }
    // Simple positional substitution if delegate not yet bound
    if (args != null && args.isNotEmpty) {
      String text = source;
      for (var i = 0; i < args.length; i++) {
        text = text.replaceAll('{$i}', args[i].toString());
      }
      return text;
    }
    return source;
  }
}

/// Dynamic translation helper alias, matching Frappe's standard format.
String tr(String source, [List<Object>? args]) =>
    FrappeTranslations.translate(source, args);
