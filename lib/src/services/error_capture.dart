import 'dart:convert';

import '../api/exceptions.dart';
import '../sync/error_log_collector.dart';
import '../sync/mobile_error_record.dart';
import '../utils/sdk_log.dart';

/// Records a terminal push HTTP failure into [collector]. Only HTTP failures
/// with a 4XX/5XX status are recorded — transient `NetworkException`/
/// `TimeoutException` (no/again status) are out of scope (spec §6). The
/// caller still rethrows the original exception; this is a pure side-channel.
void recordTerminalFailure({
  required ErrorLogCollector collector,
  required String method,
  required Map<String, Object?> payload,
  required FrappeException error,
  required String sessionUserName,
  required List<String> sessionUserRoles,
  required int nowMillis,
}) {
  final status = error.statusCode;
  if (status == null || status < 400) return; // out of scope

  final mobileUuid = (payload['mobile_uuid'] as String?) ?? '';
  final doctype = (payload['doctype'] as String?) ?? '';

  collector.record(
    MobileErrorRecord(
      doctype: doctype,
      operation: operationName(method),
      httpStatus: status,
      excType: excTypeFromBody(error.responseBodyRaw),
      errorUser: sessionUserName,
      errorUserRoles: sessionUserRoles,
      requestMethod: error.requestMethod ?? method,
      requestUrl: error.requestUrl ?? '',
      requestPayload: error.requestBody != null
          ? jsonEncode(error.requestBody)
          : jsonEncode(payload),
      responseBody: error.responseBodyRaw,
      traceId: error.traceId,
      mobileUuid: mobileUuid,
      message: error.message,
      occurredAtMillis: nowMillis,
    ),
  );
}

/// Best-effort variant of [recordTerminalFailure] that NEVER throws. The push
/// engine invokes this from a `catch` block *before* rethrowing the original
/// `FrappeException`; if capture were to throw (e.g. an unencodable body or a
/// non-String `mobile_uuid`/`doctype` failing its cast) it would mask the real
/// sync failure. Any error here is swallowed and logged.
void recordTerminalFailureSafe({
  required ErrorLogCollector collector,
  required String method,
  required Map<String, Object?> payload,
  required FrappeException error,
  required String sessionUserName,
  required List<String> sessionUserRoles,
  required int nowMillis,
}) {
  try {
    recordTerminalFailure(
      collector: collector,
      method: method,
      payload: payload,
      error: error,
      sessionUserName: sessionUserName,
      sessionUserRoles: sessionUserRoles,
      nowMillis: nowMillis,
    );
  } catch (e, st) {
    sdkLog('recordTerminalFailureSafe: capture failed (ignored) — $e\n$st');
  }
}
