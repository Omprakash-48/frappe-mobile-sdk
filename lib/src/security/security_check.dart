/// Identifies which tamper-detection check failed.
/// Pass a [Set<SecurityCheck>] to [FrappeSecurityService] to control
/// exactly which checks are active for your threat model.
enum SecurityCheck {
  /// Device is rooted (Android) or jailbroken (iOS).
  root,

  /// GPS mock provider is active — `Position.isMocked` is true.
  mockLocation,

  /// Wall clock moved backwards since the last [FrappeSecurityService.runChecks] call.
  timeRollback,

  /// Native monotonic clock (`SystemClock.elapsedRealtime` / `ProcessInfo.systemUptime`)
  /// is lower than the value stored at the previous run, and the current monotonic
  /// value exceeds [FrappeSecurityService.restartGapMs] (ruling out a genuine reboot).
  monotonicRollback,

  /// Device wall clock is before the latest server-generated document timestamp
  /// stored in any `doctype_meta.last_ok_cursor`. Skipped automatically when no
  /// sync cursor exists.
  serverTimeAnchor,
}
