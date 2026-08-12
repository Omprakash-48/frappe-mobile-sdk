import '../api/exceptions.dart';
// For the `ErrorCode.isTerminal` extension.
import '../models/outbox_row.dart';
import 'push_error.dart';

/// Frappe exception names that can never succeed on retry, matched against the
/// error text as a belt-and-braces check for cases where the typed information
/// has been flattened (e.g. an exception re-thrown as a plain [Exception]).
const List<String> _terminalMarkers = <String>[
  'MaxFileSizeReachedError',
  'FileTypeNotAllowed',
];

/// 4xx statuses that ARE worth retrying despite the client-error class.
const Set<int> _retryable4xx = <int>{
  408, // Request Timeout
  429, // Too Many Requests
};

/// True when [error] can never succeed on retry, so the attachment must go to
/// `rejected` (blocking the parent push with an actionable reason) rather than
/// `failed` (retried automatically on the next dispatch).
///
/// Defaults to FALSE for anything unrecognised. A wrongly-transient error costs
/// one retry; a wrongly-terminal one strands the user's file with no automatic
/// recovery. Fail toward retrying.
///
/// Grounded in what the upload path actually throws: `RestHelper._handleResponse`
/// raises [ValidationException] on 417, [AuthException] on 401/403,
/// [ApiException] otherwise, and [NetworkException] on transport failure.
bool isTerminalAttachmentError(Object error) {
  // Push-layer type, in case an upload is ever routed through that machinery.
  if (error is ServerRejection) return error.toErrorCode().isTerminal;

  // Transport failure — always worth another attempt.
  if (error is NetworkException) return false;

  // HTTP 417. Frappe's `frappe.throw` lands here, which is how an oversized
  // file (MaxFileSizeReachedError) reaches the client.
  if (error is ValidationException) return true;

  if (error is AuthException) {
    // 403 = this user may not upload here; no retry will change that.
    // 401 = the credential expired. The SDK's refresh machinery handles it and
    // a later attempt succeeds, so rejecting here would strand the file behind
    // a re-login.
    return error.statusCode == 403;
  }

  if (error is FrappeException) {
    final status = error.statusCode;
    if (status == null) return false;
    if (_retryable4xx.contains(status)) return false;
    // Other 4xx are client errors that will repeat identically; 5xx are
    // server-side and may clear.
    return status >= 400 && status < 500;
  }

  final text = error.toString();
  for (final marker in _terminalMarkers) {
    if (text.contains(marker)) return true;
  }
  return false;
}
