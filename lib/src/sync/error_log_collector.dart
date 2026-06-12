import 'mobile_error_record.dart';

/// Max example payloads retained per signature (rolling, newest-wins).
const int kMaxErrorExamples = 5;

/// One example payload for the aggregated POST.
class ErrorExample {
  final String mobileUuid;
  final String? requestPayload;
  final String? responseBody;
  final int occurredAtMillis;
  const ErrorExample({
    required this.mobileUuid,
    required this.requestPayload,
    required this.responseBody,
    required this.occurredAtMillis,
  });

  Map<String, Object?> toJson() => {
    'mobile_uuid': mobileUuid,
    'request_payload': requestPayload,
    'response_body': responseBody,
    'occurred_at_millis': occurredAtMillis,
  };
}

/// One aggregated signature group, ready to POST.
class AggregatedError {
  final String signature;
  final String doctype;
  final String operation;
  final int httpStatus;
  final String excType;
  final String errorUser;
  final List<String> errorUserRoles;
  final String requestMethod;
  final String requestUrl;
  final String? traceId;
  final int occurrenceCount;
  final int lastSeenMillis;
  final List<ErrorExample> examples;

  AggregatedError({
    required this.signature,
    required this.doctype,
    required this.operation,
    required this.httpStatus,
    required this.excType,
    required this.errorUser,
    required this.errorUserRoles,
    required this.requestMethod,
    required this.requestUrl,
    required this.traceId,
    required this.occurrenceCount,
    required this.lastSeenMillis,
    required this.examples,
  });

  Map<String, Object?> toJson() => {
    'signature': signature,
    'doctype_name': doctype,
    'operation': operation,
    'http_status': httpStatus,
    'exc_type': excType,
    'error_user': errorUser,
    'error_user_roles': errorUserRoles,
    'request_method': requestMethod,
    'request_url': requestUrl,
    'trace_id': traceId,
    'occurrence_count': occurrenceCount,
    'last_seen_millis': lastSeenMillis,
    'examples': examples.map((e) => e.toJson()).toList(),
  };
}

class _Agg {
  final MobileErrorRecord first;
  int count = 0;
  int lastSeenMillis = 0;
  String errorUser;
  List<String> roles;
  final List<ErrorExample> examples = [];
  _Agg(this.first) : errorUser = first.errorUser, roles = first.errorUserRoles;
}

/// Accumulates terminal push failures during one drain, grouped by signature.
/// Not thread-safe by design: the push pool's `send` calls are awaited within
/// one drain, and [drain] is called once at drain completion.
class ErrorLogCollector {
  final Map<String, _Agg> _bySig = {};

  void record(MobileErrorRecord r) {
    final sig = computeSignature(r);
    final agg = _bySig.putIfAbsent(sig, () => _Agg(r));
    agg.count += 1;
    if (r.occurredAtMillis >= agg.lastSeenMillis) {
      agg.lastSeenMillis = r.occurredAtMillis;
      agg.errorUser = r.errorUser; // latest snapshot
      agg.roles = r.errorUserRoles;
    }
    agg.examples.add(
      ErrorExample(
        mobileUuid: r.mobileUuid,
        requestPayload: r.requestPayload,
        responseBody: r.responseBody,
        occurredAtMillis: r.occurredAtMillis,
      ),
    );
    // Rolling last-N: keep the most recent kMaxErrorExamples by occurredAt.
    if (agg.examples.length > kMaxErrorExamples) {
      agg.examples.sort(
        (a, b) => a.occurredAtMillis.compareTo(b.occurredAtMillis),
      );
      agg.examples.removeRange(0, agg.examples.length - kMaxErrorExamples);
    }
  }

  /// Returns one [AggregatedError] per signature and clears all state.
  List<AggregatedError> drain() {
    final out = <AggregatedError>[];
    for (final entry in _bySig.entries) {
      final a = entry.value;
      final examples = List<ErrorExample>.from(a.examples)
        ..sort((x, y) => x.occurredAtMillis.compareTo(y.occurredAtMillis));
      out.add(
        AggregatedError(
          signature: entry.key,
          doctype: a.first.doctype,
          operation: a.first.operation,
          httpStatus: a.first.httpStatus,
          excType: a.first.excType,
          errorUser: a.errorUser,
          errorUserRoles: a.roles,
          requestMethod: a.first.requestMethod,
          requestUrl: a.first.requestUrl,
          traceId: a.first.traceId,
          occurrenceCount: a.count,
          lastSeenMillis: a.lastSeenMillis,
          examples: examples,
        ),
      );
    }
    _bySig.clear();
    return out;
  }
}

/// Load-bearing structural key + a normalized-message tiebreaker, hashed to a
/// fixed-length hex string (fits Frappe's 140-char Data field). FNV-1a 64-bit
/// — dependency-free and deterministic; collisions are negligible at this
/// cardinality.
String computeSignature(MobileErrorRecord r) {
  final structural =
      '${r.excType}|${r.doctype}|${r.operation}|${r.httpStatus}|${r.errorUser}';
  final tiebreaker = _normalizeMessage(r.message);
  return _fnv1a64Hex('$structural|$tiebreaker');
}

/// Strips per-record specifics so "row 7" and "row 3" collapse: digits, UUIDs,
/// quoted strings. Deliberately a tiebreaker only — never load-bearing.
String _normalizeMessage(String? message) {
  if (message == null || message.isEmpty) return '';
  var m = message.toLowerCase();
  m = m.replaceAll(
    RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'),
    '<uuid>',
  );
  m = m.replaceAll(RegExp(r'"[^"]*"'), '<q>');
  m = m.replaceAll(RegExp(r"'[^']*'"), '<q>');
  m = m.replaceAll(RegExp(r'\d+'), '<n>');
  m = m.replaceAll(RegExp(r'\s+'), ' ').trim();
  return m;
}

String _fnv1a64Hex(String input) {
  // 64-bit FNV-1a over UTF-16 code units (sufficient & stable for our keys).
  var hash = BigInt.parse('14695981039346656037');
  final prime = BigInt.parse('1099511628211');
  final mask = (BigInt.one << 64) - BigInt.one;
  for (final c in input.codeUnits) {
    hash = (hash ^ BigInt.from(c)) & mask;
    hash = (hash * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
