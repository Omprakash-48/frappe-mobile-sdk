import 'package:flutter/material.dart';

import '../../api/utils.dart';
import '../../models/outbox_row.dart';
import '../widgets/screen_helpers.dart';

/// List of currently-erroring outbox rows, grouped by doctype with
/// per-row Retry / View error / Open actions and a header `Retry all`
/// button. Spec §7.2.
///
/// Stateless — caller owns the row list and the action callbacks. Wire
/// to [SyncController.pendingErrors], `.retry`, `.retryAll`, `.cancel`.
/// `retryAllRunning` disables per-row Retry buttons (as the engine
/// drains the queue in priority order) and swaps the header button
/// from `Retry all` → `Stop`.
///
/// For a [OutboxState.paused] row, the per-row Retry uses [onRetryPaused] when
/// supplied (wire it to `SyncController.retryPaused`) so the paused-row
/// recovery path is taken explicitly rather than routing through the generic
/// [onRetry]. When [onRetryPaused] is null, paused rows fall back to [onRetry].
class SyncErrorsScreen extends StatelessWidget {
  final List<OutboxRow> rows;
  final Future<void> Function(int outboxId) onRetry;

  /// Recovery action for [OutboxState.paused] rows. Optional for backward
  /// compatibility; falls back to [onRetry] when not provided.
  final Future<void> Function(int outboxId)? onRetryPaused;
  final Future<void> Function() onRetryAll;
  final Future<void> Function() onStop;
  final void Function(OutboxRow) onOpen;
  final void Function(OutboxRow) onViewError;
  final bool retryAllRunning;

  const SyncErrorsScreen({
    super.key,
    required this.rows,
    required this.onRetry,
    this.onRetryPaused,
    required this.onRetryAll,
    required this.onStop,
    required this.onOpen,
    required this.onViewError,
    required this.retryAllRunning,
  });

  /// Routes a row's per-row Retry to the state-appropriate action.
  Future<void> _retryRow(OutboxRow r) {
    if (r.state == OutboxState.paused && onRetryPaused != null) {
      return onRetryPaused!(r.id);
    }
    return onRetry(r.id);
  }

  @override
  Widget build(BuildContext context) {
    final byDoctype = <String, List<OutboxRow>>{};
    for (final r in rows) {
      byDoctype.putIfAbsent(r.doctype, () => []).add(r);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync errors'),
        actions: [
          if (retryAllRunning)
            TextButton(
              onPressed: () => _runAndSurface(context, onStop, 'Stop'),
              child: const Text('Stop'),
            )
          else
            TextButton(
              onPressed: rows.isEmpty
                  ? null
                  : () => _runAndSurface(context, onRetryAll, 'Retry all'),
              child: const Text('Retry all'),
            ),
        ],
      ),
      body: rows.isEmpty
          ? _buildEmptyState(context)
          : ListView(
              children: byDoctype.entries.map((e) {
                return ExpansionTile(
                  initiallyExpanded: true,
                  title: Text('${e.key} (${e.value.length})'),
                  children: e.value.map((r) {
                    return ListTile(
                      title: Text(r.mobileUuid),
                      subtitle: Text(
                        '${r.errorCode?.name ?? ""} · ${r.errorMessage ?? ""}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          OutlinedButton(
                            onPressed: retryAllRunning
                                ? null
                                : () => _runAndSurface(
                                    context,
                                    () => _retryRow(r),
                                    'Retry',
                                  ),
                            child: const Text('Retry'),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            icon: const Icon(Icons.info_outline),
                            tooltip: 'View error',
                            onPressed: () => onViewError(r),
                          ),
                          IconButton(
                            icon: const Icon(Icons.open_in_new),
                            tooltip: 'Open',
                            onPressed: () => onOpen(r),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              }).toList(),
            ),
    );
  }

  /// Awaits an async button action and surfaces any error via SnackBar.
  /// Without this, `onPressed: someFutureFn` lets Dart silently discard
  /// the returned Future, turning async exceptions into uncaught zone
  /// errors that never reach the user (PR#36 round-2 M12).
  Future<void> _runAndSurface(
    BuildContext context,
    Future<void> Function() action,
    String label,
  ) async {
    try {
      await action();
    } catch (e, st) {
      debugPrint('SyncErrorsScreen: $label failed — $e\n$st');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$label failed: ${toUserFriendlyMessage(e)}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);
    return EmptyStateWidget(
      icon: Icons.check_circle_outline,
      iconColor: theme.colorScheme.primary,
      title: 'No sync errors',
      subtitle: 'All queued changes have synced successfully.',
      // Original used onSurfaceVariant (theme-adaptive in dark mode);
      // preserve exactly instead of the helper's grey-600 default.
      subtitleStyle: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
