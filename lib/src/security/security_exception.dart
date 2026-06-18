import 'security_check.dart';

/// Thrown by [FrappeSecurityService.runChecks] when one or more enabled
/// checks detect a tamper condition. [failedChecks] contains every check
/// that fired — all checks run before this is thrown.
class SecurityCannotBeAssuredException implements Exception {
  const SecurityCannotBeAssuredException(this.failedChecks);

  final Set<SecurityCheck> failedChecks;

  @override
  String toString() =>
      'SecurityCannotBeAssuredException: '
      '${failedChecks.map((c) => c.name).join(', ')}';
}
