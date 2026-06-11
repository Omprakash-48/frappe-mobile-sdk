// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Best-effort diagnostic logging for the SDK. Stripped in release builds.

import 'package:flutter/foundation.dart';

/// Logs a best-effort diagnostic message — typically from a catch block whose
/// failure is non-fatal and must not be silent during development.
///
/// Replaces the scattered raw-stdout calls and their lint suppressors that
/// accumulated across the SDK. Routes through [debugPrint] (throttled and
/// lint-clean, so no per-call suppressor is needed) and compiles out entirely
/// in release via the [kDebugMode] guard.
void sdkLog(String message) {
  if (!kDebugMode) return;
  debugPrint(message);
}
