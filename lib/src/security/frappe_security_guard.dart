import 'package:flutter/material.dart';

import '../utils/sdk_log.dart';
import 'frappe_security_service.dart';
import 'security_check.dart';
import 'security_exception.dart';

/// Wraps its [child] and runs [service.runChecks] on mount.
///
/// When all checks pass (or the service is disabled), renders [child] normally.
/// When [SecurityCannotBeAssuredException] is thrown, replaces [child] with
/// [blockingScreen] (or the built-in default). Any other exception is logged
/// and treated as a pass to avoid bricking the app on transient errors.
class FrappeSecurityGuard extends StatefulWidget {
  const FrappeSecurityGuard({
    super.key,
    required this.service,
    required this.child,
    this.blockingScreen,
  });

  final FrappeSecurityService service;
  final Widget child;

  /// Optional custom screen to show on failure. When null the SDK's default
  /// lock screen is shown with a list of failed check labels.
  final Widget? blockingScreen;

  @override
  State<FrappeSecurityGuard> createState() => _FrappeSecurityGuardState();
}

class _FrappeSecurityGuardState extends State<FrappeSecurityGuard> {
  bool _checking = true;
  Set<SecurityCheck>? _failedChecks;

  /// Set once a [SecurityCheck.root] failure is seen and never cleared for the
  /// life of this widget state. In-process retry is then disabled — see
  /// [_retry]. This closes a Magisk-hide style bypass: on a rooted device an
  /// attacker could trigger the block, add this app to Magisk's DenyList
  /// (which hides root from the process *without* a reboot), then tap Retry to
  /// re-run the check and unlock. A root verdict is therefore sticky and only
  /// resets on a genuine process restart (which constructs a fresh state).
  bool _rootPermanentlyBlocked = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  /// Re-runs the integrity checks after a block. Lets the user recover from a
  /// transient false positive (e.g. a momentary clock skew) without having to
  /// force-kill and relaunch the app. A root failure is never retryable
  /// in-process — see [_rootPermanentlyBlocked].
  void _retry() {
    if (!mounted || _rootPermanentlyBlocked) return;
    setState(() {
      _checking = true;
      _failedChecks = null;
    });
    _run();
  }

  Future<void> _run() async {
    if (!widget.service.enabled) {
      if (mounted) setState(() => _checking = false);
      return;
    }
    try {
      await widget.service.runChecks();
      if (mounted) setState(() => _checking = false);
    } on SecurityCannotBeAssuredException catch (e) {
      final rootFailed = e.failedChecks.contains(SecurityCheck.root);
      if (mounted) {
        setState(() {
          _checking = false;
          _failedChecks = e.failedChecks;
          if (rootFailed) _rootPermanentlyBlocked = true;
        });
      } else if (rootFailed) {
        _rootPermanentlyBlocked = true;
      }
    } catch (e, st) {
      sdkLog('FrappeSecurityGuard: unexpected error — $e\n$st');
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_failedChecks != null) {
      return widget.blockingScreen ??
          _SecurityBlockScreen(
            failedChecks: _failedChecks!,
            // No Retry affordance once root is confirmed — see
            // [_rootPermanentlyBlocked].
            onRetry: _rootPermanentlyBlocked ? null : _retry,
          );
    }
    return widget.child;
  }
}

class _SecurityBlockScreen extends StatelessWidget {
  const _SecurityBlockScreen({required this.failedChecks, this.onRetry});

  final Set<SecurityCheck> failedChecks;

  /// Re-runs the checks. When null, no retry affordance is shown.
  final VoidCallback? onRetry;

  static String _label(SecurityCheck c) => switch (c) {
    SecurityCheck.root => 'Device is rooted or jailbroken',
    SecurityCheck.mockLocation => 'Mock GPS location detected',
    SecurityCheck.timeRollback => 'Device clock has been rolled back',
    SecurityCheck.monotonicRollback => 'System time inconsistency detected',
    SecurityCheck.serverTimeAnchor =>
      'Device clock is behind last known server time',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock, size: 80, color: Colors.red),
              const SizedBox(height: 24),
              const Text(
                'Security Check Failed',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...failedChecks.map(
                (c) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• ${_label(c)}', textAlign: TextAlign.center),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'This device does not meet security requirements. '
                'Please contact your administrator.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
