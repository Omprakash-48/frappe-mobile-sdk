/// Liveness of the stored credential, published by `AuthService` so a host app
/// can react instead of watching every request fail.
enum SessionHealth {
  /// Credentials are good, or no refresh has been attempted yet.
  healthy,

  /// A refresh failed for a reason that may clear by itself — transport
  /// failure, 5xx, or a per-user rate limit. The token is still stored and
  /// will be retried after a cooldown. Hosts should NOT prompt for re-login.
  degraded,

  /// A refresh was DEFINITIVELY rejected (401/403/417). Only a fresh login
  /// recovers. Hosts should prompt. Nothing is wiped by this state.
  expired,
}
