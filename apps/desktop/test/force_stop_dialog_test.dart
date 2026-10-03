import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/frontend/features/runtime_control/force_stop_dialog.dart';
import 'package:licoup/src/frontend/features/runtime_control/work_stop_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('the force-stop dialog shows the affected tasks and the risk', (
    tester,
  ) async {
    await _pumpDialogHost(tester);

    expect(find.byKey(const Key('force-stop-dialog')), findsOneWidget);
    expect(find.text('Tasks that stop (2)'), findsOneWidget);
    expect(find.text('agent-turn · opencode:session-1'), findsOneWidget);
    expect(find.text('agent-turn · opencode:session-2'), findsOneWidget);
    expect(find.text('Running tasks lose unsaved progress.'), findsOneWidget);
    expect(
      find.text('The service must be started again afterwards.'),
      findsOneWidget,
    );
    expect(find.text('Diagnostic reference: force:preview-1'), findsOneWidget);
  });

  testWidgets('keep waiting resolves false and sends nothing', (tester) async {
    await _pumpDialogHost(tester);

    await tester.tap(find.byKey(const Key('force-stop-continue-waiting')));
    await tester.pumpAndSettle();

    expect(_result, isFalse);
    expect(find.byKey(const Key('force-stop-dialog')), findsNothing);
  });

  testWidgets('only the explicit force-stop action resolves true', (
    tester,
  ) async {
    await _pumpDialogHost(tester);

    await tester.tap(find.byKey(const Key('force-stop-confirm')));
    await tester.pumpAndSettle();

    expect(_result, isTrue);
  });

  testWidgets('the dialog never confirms or counts down on its own', (
    tester,
  ) async {
    await _pumpDialogHost(tester);

    // Ten seconds of frames: still open, still unresolved.
    for (var index = 0; index < 20; index += 1) {
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('force-stop-dialog')), findsOneWidget);
    }
    expect(_result, isNull);
  });

  testWidgets('the stop indicator renders the projected stage', (tester) async {
    await _pumpIndicator(
      tester,
      const WorkStopIndicator(
        stage: WorkStopStage.stopping,
        diagnosticReference: 'stop:corr-1',
      ),
    );

    expect(find.text('Stopping…'), findsOneWidget);
    expect(find.text('stop:corr-1'), findsOneWidget);
    expect(find.byKey(const Key('work-stop-force')), findsNothing);
  });

  testWidgets('an idle stage renders nothing', (tester) async {
    await _pumpIndicator(
      tester,
      const WorkStopIndicator(stage: WorkStopStage.idle),
    );

    expect(find.byKey(const Key('work-stop-indicator')), findsNothing);
  });

  testWidgets('an unconfirmed stop offers the explicit force-stop route', (
    tester,
  ) async {
    var opened = 0;
    await _pumpIndicator(
      tester,
      WorkStopIndicator(
        stage: WorkStopStage.unconfirmed,
        diagnosticReference: 'stop:corr-9',
        onForceStop: () => opened += 1,
      ),
    );

    expect(find.text('Stop unconfirmed'), findsOneWidget);
    expect(find.text('stop:corr-9'), findsOneWidget);
    await tester.tap(find.byKey(const Key('work-stop-force')));
    expect(opened, 1);
  });
}

bool? _result;

Future<void> _pumpDialogHost(WidgetTester tester) async {
  _result = null;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLicoTheme(platformBrightness: Brightness.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                _result = await showForceStopDialog(
                  context,
                  preview: _preview,
                  chinese: false,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _pumpIndicator(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLicoTheme(platformBrightness: Brightness.light),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  await tester.pump();
}

const _preview = ForceStopPreview(
  status: ForceStopPreviewStatus.preview,
  correlationId: 'preview-1',
  scopeId: 'local-service.opencode',
  ownerKind: 'local-service',
  ownerRef: 'opencode',
  processGroupVerified: true,
  affectedTaskCount: 2,
  affectedTasks: [
    ForceStopAffectedTask(
      taskKind: 'agent-turn',
      taskRef: 'opencode:session-1',
    ),
    ForceStopAffectedTask(
      taskKind: 'agent-turn',
      taskRef: 'opencode:session-2',
    ),
  ],
  riskCodes: ['unsaved-agent-progress', 'service-restart-required'],
  confirmationToken: 'token-1',
);
