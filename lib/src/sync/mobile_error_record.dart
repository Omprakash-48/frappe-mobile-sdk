import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../utils/sdk_log.dart';

/// Maps an SDK HTTP method (as passed to the push `send` callback) to the
/// Frappe document operation recorded in the error log.
String operationName(String method) {
  switch (method.toUpperCase()) {
    case 'POST':
      return 'INSERT';
    case 'PUT':
      return 'UPDATE';
    case 'SUBMIT':
      return 'SUBMIT';
    case 'CANCEL':
      return 'CANCEL';
    case 'DELETE':
      return 'DELETE';
    default:
      return method.toUpperCase();
  }
}

/// Pulls Frappe's `exc_type` out of a raw JSON response body. Returns ''
/// when the body is null or not the expected JSON shape — `exc_type` is a
/// load-bearing signature key, so a missing value must be stable (''), not
/// throw.
String excTypeFromBody(String? rawBody) {
  if (rawBody == null || rawBody.isEmpty) return '';
  try {
    final decoded = jsonDecode(rawBody);
    if (decoded is Map && decoded['exc_type'] is String) {
      return decoded['exc_type'] as String;
    }
  } catch (e, st) {
    sdkLog('excTypeFromBody: decode failed — $e\n$st');
  }
  return '';
}

/// One captured terminal push failure, before per-drain aggregation.
@immutable
class MobileErrorRecord {
  final String doctype;
  final String operation; // INSERT/UPDATE/...
  final int httpStatus;
  final String excType;
  final String errorUser; // client's last-known session user
  final List<String> errorUserRoles;
  final String requestMethod;
  final String requestUrl; // full, incl. base URL
  final String? requestPayload; // JSON string of the wire body
  final String? responseBody; // raw server response
  final String? traceId;
  final String mobileUuid;
  final String? message; // server message, for normalized-message tiebreaker
  final int occurredAtMillis;

  const MobileErrorRecord({
    required this.doctype,
    required this.operation,
    required this.httpStatus,
    required this.excType,
    required this.errorUser,
    required this.errorUserRoles,
    required this.requestMethod,
    required this.requestUrl,
    required this.requestPayload,
    required this.responseBody,
    required this.traceId,
    required this.mobileUuid,
    required this.message,
    required this.occurredAtMillis,
  });
}
