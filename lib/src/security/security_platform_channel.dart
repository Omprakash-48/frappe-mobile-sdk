import 'package:flutter/services.dart';

/// Thin wrapper around the `frappe_mobile_sdk/security` MethodChannel.
/// Returns `null` in test environments or when the channel is unregistered.
class SecurityPlatformChannel {
  static const _channel = MethodChannel('frappe_mobile_sdk/security');

  /// Returns milliseconds since device boot (`SystemClock.elapsedRealtime` on
  /// Android, `CLOCK_MONOTONIC_RAW` on iOS). Returns `null` when
  /// the native plugin is unavailable (unit tests, unsupported platforms).
  static Future<int?> getMonotonicMillis() async {
    try {
      return await _channel.invokeMethod<int>('getMonotonicMillis');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
