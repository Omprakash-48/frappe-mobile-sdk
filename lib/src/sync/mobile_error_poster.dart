import '../utils/sdk_log.dart';
import 'error_log_collector.dart';

/// The mobile_control whitelisted method that ingests error logs.
const String kReportErrorMethod = 'mobile_sync.report_error';

/// Signature of `FrappeClient.call` — injected so the poster is testable
/// without a live client.
typedef ErrorLogCallFn =
    Future<dynamic> Function(String method, Map<String, dynamic> args);

/// Best-effort delivery of aggregated error logs. POST failures are swallowed
/// and logged — this is telemetry, not a guaranteed audit log (spec §9 #1).
class MobileErrorPoster {
  final ErrorLogCallFn call;
  MobileErrorPoster({required this.call});

  Future<void> flush(List<AggregatedError> aggregated) async {
    for (final a in aggregated) {
      try {
        // The server endpoint is `report_error(payload)` — a single named
        // argument. Wrap the aggregated record under `payload` so Frappe can
        // bind it; posting the fields flat fails with a missing-argument 500.
        await call(kReportErrorMethod, {'payload': a.toJson()});
      } catch (e, st) {
        sdkLog(
          'MobileErrorPoster: drop log for signature=${a.signature} — $e\n$st',
        );
      }
    }
  }
}
