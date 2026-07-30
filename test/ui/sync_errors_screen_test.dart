import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/ui/screens/sync_errors_screen.dart';

OutboxRow row(
  int id,
  String doctype,
  ErrorCode code, {
  OutboxState state = OutboxState.failed,
}) => OutboxRow(
  id: id,
  doctype: doctype,
  mobileUuid: '$id',
  operation: OutboxOperation.insert,
  state: state,
  errorCode: code,
  retryCount: 1,
  errorMessage: 'msg',
  createdAt: DateTime.utc(2026, 1, id),
);

void main() {
  testWidgets('shows grouped errors by doctype', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncErrorsScreen(
          rows: [
            row(1, 'Sales Order', ErrorCode.NETWORK),
            row(2, 'Sales Order', ErrorCode.VALIDATION),
            row(3, 'Customer', ErrorCode.PERMISSION_DENIED),
          ],
          onRetry: (id) async {},
          onRetryAll: () async {},
          onStop: () async {},
          onOpen: (row) {},
          onViewError: (row) {},
          retryAllRunning: false,
        ),
      ),
    );
    expect(find.textContaining('Sales Order'), findsOneWidget);
    expect(find.textContaining('Customer'), findsOneWidget);
    expect(find.text('Retry all'), findsOneWidget);
  });

  testWidgets('Retry button invokes callback', (tester) async {
    int? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: SyncErrorsScreen(
          rows: [row(1, 'X', ErrorCode.NETWORK)],
          onRetry: (id) async => tapped = id,
          onRetryAll: () async {},
          onStop: () async {},
          onOpen: (_) {},
          onViewError: (_) {},
          retryAllRunning: false,
        ),
      ),
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets(
    'paused row routes Retry to onRetryPaused; failed row uses onRetry (M3)',
    (tester) async {
      int? retried;
      int? retriedPaused;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncErrorsScreen(
            rows: [
              row(1, 'X', ErrorCode.VALIDATION, state: OutboxState.paused),
              row(2, 'X', ErrorCode.NETWORK),
            ],
            onRetry: (id) async => retried = id,
            onRetryPaused: (id) async => retriedPaused = id,
            onRetryAll: () async {},
            onStop: () async {},
            onOpen: (_) {},
            onViewError: (_) {},
            retryAllRunning: false,
          ),
        ),
      );
      final retryButtons = find.widgetWithText(OutlinedButton, 'Retry');
      // Row order follows insertion: paused row 1 first, failed row 2 second.
      await tester.tap(retryButtons.at(0));
      await tester.pump();
      expect(retriedPaused, 1, reason: 'paused row must use onRetryPaused');
      expect(retried, isNull);

      await tester.tap(retryButtons.at(1));
      await tester.pump();
      expect(retried, 2, reason: 'non-paused row must use onRetry');
    },
  );

  testWidgets(
    'paused row falls back to onRetry when onRetryPaused is not provided (M3)',
    (tester) async {
      int? retried;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncErrorsScreen(
            rows: [
              row(7, 'X', ErrorCode.VALIDATION, state: OutboxState.paused),
            ],
            onRetry: (id) async => retried = id,
            onRetryAll: () async {},
            onStop: () async {},
            onOpen: (_) {},
            onViewError: (_) {},
            retryAllRunning: false,
          ),
        ),
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
      await tester.pump();
      expect(retried, 7);
    },
  );

  testWidgets('per-row Retry disabled while retry-all is running', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncErrorsScreen(
          rows: [row(1, 'X', ErrorCode.NETWORK)],
          onRetry: (id) async {},
          onRetryAll: () async {},
          onStop: () async {},
          onOpen: (_) {},
          onViewError: (_) {},
          retryAllRunning: true,
        ),
      ),
    );
    final btn = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Retry'),
    );
    expect(btn.onPressed, isNull);
    expect(find.text('Stop'), findsOneWidget);
  });

  testWidgets('empty rows list shows Retry all anyway (button disabled)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncErrorsScreen(
          rows: const [],
          onRetry: (_) async {},
          onRetryAll: () async {},
          onStop: () async {},
          onOpen: (_) {},
          onViewError: (_) {},
          retryAllRunning: false,
        ),
      ),
    );
    expect(find.text('Retry all'), findsOneWidget);
  });

  testWidgets('empty state widget shows when rows is empty', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncErrorsScreen(
          rows: const [],
          onRetry: (_) async {},
          onRetryAll: () async {},
          onStop: () async {},
          onOpen: (_) {},
          onViewError: (_) {},
          retryAllRunning: false,
        ),
      ),
    );
    expect(find.text('No sync errors'), findsOneWidget);
    expect(
      find.text('All queued changes have synced successfully.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });
}
