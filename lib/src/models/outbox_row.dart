// ignore_for_file: constant_identifier_names

import '../utils/sql_row_utils.dart';

enum OutboxOperation { insert, update, submit, cancel, delete }

/// `paused` (#53): a terminal server rejection (e.g. HTTP 417 validate-hook
/// failure) parked the row out of the auto-retry loop. It re-enters `pending`
/// only when the user re-saves the record (payload changes) or explicitly
/// retries — distinct from `failed`, which the drain may still re-attempt.
enum OutboxState { pending, inFlight, done, failed, conflict, blocked, paused }

enum ErrorCode {
  NETWORK,
  TIMEOUT,
  TIMESTAMP_MISMATCH,
  LINK_EXISTS,
  PERMISSION_DENIED,
  VALIDATION,
  MANDATORY,
  UNKNOWN,
}

extension ErrorCodeHelpers on ErrorCode {
  String get wireName => name;
  static ErrorCode? parse(String? raw) =>
      parseEnumByName(ErrorCode.values, raw, fallback: ErrorCode.UNKNOWN);

  /// True when retrying can never succeed without user/server intervention
  /// (#53). The engine pauses such rows instead of looping in retry.
  ///
  /// Exhaustive switch with no `default:` — adding a future [ErrorCode] is a
  /// compile error here until its terminality is classified, so the SDK can
  /// never silently default a new error to "retryable".
  bool get isTerminal {
    switch (this) {
      case ErrorCode.VALIDATION: // server validate() hook (HTTP 417)
      case ErrorCode.MANDATORY: // missing mandatory field
      case ErrorCode.PERMISSION_DENIED: // HTTP 403
      case ErrorCode.LINK_EXISTS: // FK/link constraint
        return true;
      case ErrorCode.NETWORK:
      case ErrorCode.TIMEOUT:
      case ErrorCode.TIMESTAMP_MISMATCH:
      case ErrorCode.UNKNOWN:
        return false;
    }
  }
}

extension OutboxOperationHelpers on OutboxOperation {
  String get wireName => name.toUpperCase();
  static OutboxOperation parse(String raw) {
    switch (raw.toUpperCase()) {
      case 'INSERT':
        return OutboxOperation.insert;
      case 'UPDATE':
        return OutboxOperation.update;
      case 'SUBMIT':
        return OutboxOperation.submit;
      case 'CANCEL':
        return OutboxOperation.cancel;
      case 'DELETE':
        return OutboxOperation.delete;
    }
    throw ArgumentError.value(raw, 'operation');
  }
}

extension OutboxStateHelpers on OutboxState {
  String get wireName {
    switch (this) {
      case OutboxState.pending:
        return 'pending';
      case OutboxState.inFlight:
        return 'in_flight';
      case OutboxState.done:
        return 'done';
      case OutboxState.failed:
        return 'failed';
      case OutboxState.conflict:
        return 'conflict';
      case OutboxState.blocked:
        return 'blocked';
      case OutboxState.paused:
        return 'paused';
    }
  }

  static OutboxState parse(String raw) {
    switch (raw) {
      case 'pending':
        return OutboxState.pending;
      case 'in_flight':
        return OutboxState.inFlight;
      case 'done':
        return OutboxState.done;
      case 'failed':
        return OutboxState.failed;
      case 'conflict':
        return OutboxState.conflict;
      case 'blocked':
        return OutboxState.blocked;
      case 'paused':
        return OutboxState.paused;
    }
    throw ArgumentError.value(raw, 'state');
  }
}

class OutboxRow {
  final int id;
  final String doctype;
  final String mobileUuid;
  final String? serverName;
  final OutboxOperation operation;
  final String? payload;
  final OutboxState state;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String? errorMessage;
  final ErrorCode? errorCode;
  final DateTime createdAt;

  OutboxRow({
    required this.id,
    required this.doctype,
    required this.mobileUuid,
    this.serverName,
    required this.operation,
    this.payload,
    required this.state,
    required this.retryCount,
    this.lastAttemptAt,
    this.errorMessage,
    this.errorCode,
    required this.createdAt,
  });

  /// True when this row's error cannot be fixed by retrying (#53). UI surfaces
  /// these as "needs your attention"; the drain loop never auto-retries them.
  bool get isTerminal => errorCode?.isTerminal ?? false;

  factory OutboxRow.fromMap(Map<String, Object?> row) {
    return OutboxRow(
      id: row['id'] as int,
      doctype: row['doctype'] as String,
      mobileUuid: row['mobile_uuid'] as String,
      serverName: row['server_name'] as String?,
      operation: OutboxOperationHelpers.parse(row['operation'] as String),
      payload: row['payload'] as String?,
      state: OutboxStateHelpers.parse(row['state'] as String),
      retryCount: retryCountFrom(row),
      lastAttemptAt: lastAttemptAtFrom(row),
      errorMessage: row['error_message'] as String?,
      errorCode: ErrorCodeHelpers.parse(row['error_code'] as String?),
      createdAt: utcMillisFrom(row, 'created_at'),
    );
  }
}
