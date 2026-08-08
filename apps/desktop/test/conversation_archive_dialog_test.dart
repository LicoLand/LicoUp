import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_archive_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

import 'fixtures/client_controller/support/fake_agent_service.dart';

void main() {
  testWidgets('dialog exposes all and exact-keyword bound backup modes', (
    tester,
  ) async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.scannedTargets = service.scanTargetsResult;
    controller.selectedConversationAgentId = 'codex';
    controller.archiveDestinationDraft = 'test-data/local-archive';

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showConversationArchiveDialog(context, controller),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('conversation-archive-selection-mode')),
      findsOneWidget,
    );
    await tester.tap(find.text('Exact keyword'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('conversation-archive-exact-query')),
      'Bound topic',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('conversation-archive-confirm')));
    await tester.pump();
    for (
      var attempt = 0;
      attempt < 20 && service.archiveJobCreateCalls == 0;
      attempt += 1
    ) {
      await tester.pump();
    }

    expect(
      service.archiveJobPreviewCalls,
      1,
      reason:
          'destination=${controller.archiveDestinationDraft} '
          'query=${controller.archiveQueryDraft} '
          'collecting=${controller.isCollectingConversationArchive} '
          'error=${controller.lastError}',
    );
    expect(service.archiveSelectionMode, 'exact-keyword');
    expect(service.archiveQuery, 'Bound topic');
    expect(service.archiveSourceAgentId, 'codex');
    expect(service.archivePlanBinding, 'sha256:fake-archive-plan');
  });

  testWidgets('global all mode backs up every discovered agent scope', (
    tester,
  ) async {
    final service = FakeAgentService();
    final controller = ClientController(agentService: service);
    addTearDown(controller.dispose);
    controller.scannedTargets = service.scanTargetsResult;
    controller.selectedConversationAgentId = 'codex';
    controller.archiveDestinationDraft = 'test-data/all-local-conversations';

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showConversationArchiveDialog(
              context,
              controller,
              sourceAgentId: '',
            ),
            child: const Text('open all'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open all'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('conversation-archive-confirm')));
    for (
      var attempt = 0;
      attempt < 20 && service.archiveJobCreateCalls == 0;
      attempt += 1
    ) {
      await tester.pump();
    }

    expect(service.archiveSelectionMode, 'all');
    expect(service.archiveQuery, isEmpty);
    expect(service.archiveSourceAgentId, isEmpty);
    expect(service.archiveDestinationPath, 'test-data/all-local-conversations');
  });
}
