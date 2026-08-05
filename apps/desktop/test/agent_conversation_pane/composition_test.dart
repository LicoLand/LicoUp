import 'dart:io' show Platform;

import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';

import 'pane_test_harness.dart';

void _useComposerPopoverViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> tapRuntimeSelectorRow(WidgetTester tester, Key rowKey) async {
  final inkWell = find.descendant(
    of: find.byKey(rowKey),
    matching: find.byType(InkWell),
  );
  expect(inkWell, findsOneWidget);
  final widget = tester.widget<InkWell>(inkWell);
  widget.onTap?.call();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pane composition connects header, messages, and composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(ConversationPaneHeader), findsOneWidget);
    expect(find.byType(RuntimeMessageComposer), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'running turn pulses along the header divider, not the composer',
    (tester) async {
      await tester.pumpWidget(
        paneTestApp(
          AgentConversationActivePane(
            state: paneTestState(turnActive: true),
            actions: paneTestActions(),
            header: paneTestHeader(),
          ),
        ),
      );
      await tester.pump();

      final pulse = tester.widget<LicoTopEdgePulse>(
        find.byKey(const Key('conversation-header-running-edge')),
      );
      expect(pulse.enabled, isTrue);
      expect(
        pulse.color,
        tester
            .element(find.byType(RuntimeMessageComposer))
            .licoColors
            .primaryStrong,
      );
      expect(
        find.byKey(const Key('lico-top-edge-pulse-paint')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('agent-conversation-composer-running-edge')),
        findsNothing,
      );

      await tester.pumpWidget(
        paneTestApp(
          AgentConversationActivePane(
            state: paneTestState(turnActive: false, liveMessages: const []),
            actions: paneTestActions(),
            header: paneTestHeader(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('lico-top-edge-pulse-paint')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loading conversations pulse along the header divider', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(loading: true, liveMessages: const []),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    final pulse = tester.widget<LicoTopEdgePulse>(
      find.byKey(const Key('conversation-header-running-edge')),
    );
    expect(pulse.enabled, isTrue);
    expect(find.byKey(const Key('lico-top-edge-pulse-paint')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new conversation reveals live messages as soon as send starts', (
    tester,
  ) async {
    const recentSession = AgentConversationSession(
      id: 'recent-session',
      agentId: 'codex',
      title: 'Recent session',
      createdAt: '2026-07-23T00:00:00Z',
      updatedAt: '2026-07-23T00:00:00Z',
      messages: [],
    );

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            recentSessions: const [recentSession],
            preparingNewConversation: true,
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    expect(find.text('Recent conversations'), findsOneWidget);

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            recentSessions: const [recentSession],
            preparingNewConversation: true,
            liveMessages: const [
              AgentConversationMessage(
                id: 'synthetic-turn',
                role: 'user',
                text: 'Synthetic live prompt',
                createdAt: '2026-07-23T00:00:01Z',
              ),
            ],
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );

    expect(find.text('Recent conversations'), findsNothing);
    expect(find.text('Synthetic live prompt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new conversation exposes the working directory chooser', (
    tester,
  ) async {
    var chooserOpened = false;
    final workingDirectory = [
      '',
      'synthetic',
      'workspaces',
      'project-alpha',
    ].join('/');

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            preparingNewConversation: true,
            showWorkingDirectory: true,
            workingDirectory: workingDirectory,
            workingDirectorySelectable: true,
          ),
          actions: paneTestActions(
            onChooseWorkingDirectory: () => chooserOpened = true,
          ),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('conversation-working-directory-select')),
      findsOneWidget,
    );
    expect(find.text('Working directory · project-alpha'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('conversation-working-directory-select')),
    );
    await tester.pump();

    expect(chooserOpened, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bound conversation displays its locked working directory', (
    tester,
  ) async {
    final workingDirectory = [
      '',
      'synthetic',
      'workspaces',
      'project-alpha',
    ].join('/');

    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            showWorkingDirectory: true,
            workingDirectory: workingDirectory,
            workingDirectorySelectable: false,
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('conversation-working-directory-select')),
      findsOneWidget,
    );
    expect(find.text('Working directory · project-alpha'), findsOneWidget);
    expect(
      tester
          .widget<InkWell>(
            find.descendant(
              of: find.byKey(
                const ValueKey('conversation-working-directory-select'),
              ),
              matching: find.byType(InkWell),
            ),
          )
          .onTap,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('completed failed send remains visible beside the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            turnActive: false,
            sendGateReasonCode: 'native_agent_transport_failed',
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-send-failed')), findsOneWidget);
    expect(
      find.byKey(const Key('conversation-send-failed-reason')),
      findsOneWidget,
    );
    expect(
      find.textContaining('native_agent_transport_failed'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('conversation-send-failed-action')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('driver failure codes surface verbatim beside the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            turnActive: false,
            sendGateReasonCode: 'hermes_gateway_protocol_timeout',
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('hermes_gateway_protocol_timeout'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'auth-required failure offers an explicit authorize action only',
    (tester) async {
      var authorizeTapped = 0;
      await tester.pumpWidget(
        paneTestApp(
          AgentConversationActivePane(
            state: paneTestState(
              turnActive: false,
              sendGateReasonCode: 'antigravity_auth_required',
            ),
            actions: paneTestActions(onUnblockSend: () => authorizeTapped += 1),
            header: paneTestHeader(),
          ),
        ),
      );
      await tester.pump();

      final action = find.byKey(const Key('conversation-send-failed-action'));
      expect(action, findsOneWidget);
      expect(find.text('Authorize'), findsOneWidget);
      await tester.tap(action);
      expect(authorizeTapped, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('authorize action is disabled while authorization runs', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            turnActive: false,
            sendGateReasonCode: 'antigravity_auth_required',
            sendAuthorizeActive: true,
          ),
          actions: paneTestActions(onUnblockSend: () {}),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Authorizing…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const Key('conversation-send-failed-action')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('messaging workspace button shows the home directory as ~', (
    tester,
  ) async {
    final home =
        (Platform.environment['HOME'] ??
                Platform.environment['USERPROFILE'] ??
                '')
            .trim();
    expect(home, isNotEmpty);

    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: AgentConversationActivePane(
            state: paneTestState(
              preparingNewConversation: true,
              showWorkingDirectory: true,
              workingDirectory: home,
              workingDirectorySelectable: true,
            ),
            actions: paneTestActions(onChooseWorkingDirectory: () {}),
            header: paneTestHeader(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-workspace-button')),
      findsOneWidget,
    );
    expect(find.text('~', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'messaging workspace button opens the chooser and follows the selection',
    (tester) async {
      var chooserOpened = false;
      final home = (Platform.environment['HOME'] ?? '').trim();
      final selected = '$home/DevSpace/LicoLand';

      await tester.pumpWidget(
        paneTestApp(
          LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: AgentConversationActivePane(
              state: paneTestState(
                preparingNewConversation: true,
                showWorkingDirectory: true,
                workingDirectory: home,
                workingDirectorySelectable: true,
              ),
              actions: paneTestActions(
                onChooseWorkingDirectory: () => chooserOpened = true,
              ),
              header: paneTestHeader(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('conversation-workspace-button')));
      await tester.pump();
      expect(chooserOpened, isTrue);

      // The picker round-trip lands in the pane state; the button then shows
      // the newly selected directory, shortened against home.
      await tester.pumpWidget(
        paneTestApp(
          LayoutAgentsStrategyScope(
            strategy: const AgentsPresentationStrategy.messaging(),
            child: AgentConversationActivePane(
              state: paneTestState(
                preparingNewConversation: true,
                showWorkingDirectory: true,
                workingDirectory: selected,
                workingDirectorySelectable: true,
              ),
              actions: paneTestActions(onChooseWorkingDirectory: () {}),
              header: paneTestHeader(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('~/DevSpace/LicoLand', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('messaging workspace button middle-ellipsizes long paths', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: AgentConversationActivePane(
            state: paneTestState(
              showWorkingDirectory: true,
              workingDirectory:
                  '/synthetic/workspaces/with/a/very/deep/nesting/for/the/project-alpha',
              workingDirectorySelectable: false,
            ),
            actions: paneTestActions(),
            header: paneTestHeader(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('/synthetic/…/project-alpha', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('messaging workspace button shows a bound directory locked', (
    tester,
  ) async {
    var chooserOpened = false;

    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: AgentConversationActivePane(
            state: paneTestState(
              showWorkingDirectory: true,
              workingDirectory: '/synthetic/workspaces/project-alpha',
              workingDirectorySelectable: false,
            ),
            actions: paneTestActions(
              onChooseWorkingDirectory: () => chooserOpened = true,
            ),
            header: paneTestHeader(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-workspace-button')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);

    await tester.tap(find.byKey(const Key('conversation-workspace-button')));
    await tester.pump();
    expect(chooserOpened, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('console strategy keeps the workspace button off the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            preparingNewConversation: true,
            showWorkingDirectory: true,
            workingDirectory: '/synthetic/workspaces/project-alpha',
            workingDirectorySelectable: true,
          ),
          actions: paneTestActions(onChooseWorkingDirectory: () {}),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('conversation-workspace-button')),
      findsNothing,
    );
    // The console keeps its runtime-bar chip instead.
    expect(
      find.byKey(const ValueKey('conversation-working-directory-select')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('messaging model capsule shows the selected model short name', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: AgentConversationActivePane(
            state: paneTestState(
              modelOptions: const ['gpt-5.4-mini', 'gpt-5.5'],
              selectedModel: 'gpt-5.4-mini',
            ),
            actions: paneTestActions(),
            header: paneTestHeader(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-model-button')), findsOneWidget);
    expect(find.text('gpt-5.4-mini'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('messaging model capsule opens the model menu', (tester) async {
    _useComposerPopoverViewport(tester);
    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: AgentConversationActivePane(
            state: paneTestState(
              modelOptions: const ['gpt-5.4-mini', 'gpt-5.5'],
              selectedModel: 'gpt-5.4-mini',
            ),
            actions: paneTestActions(),
            header: paneTestHeader(),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('conversation-model-button')));
    await tester.pumpAndSettle();
    await tapRuntimeSelectorRow(
      tester,
      const Key('conversation-runtime-model-row'),
    );
    expect(find.text('gpt-5.5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('messaging hides model capsule without catalog options', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        LayoutAgentsStrategyScope(
          strategy: const AgentsPresentationStrategy.messaging(),
          child: AgentConversationActivePane(
            state: paneTestState(modelOptions: const []),
            actions: paneTestActions(),
            header: paneTestHeader(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-model-button')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('console strategy keeps the model capsule off the composer', (
    tester,
  ) async {
    await tester.pumpWidget(
      paneTestApp(
        AgentConversationActivePane(
          state: paneTestState(
            modelOptions: const ['gpt-5.5'],
            selectedModel: 'gpt-5.5',
          ),
          actions: paneTestActions(),
          header: paneTestHeader(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-model-button')), findsNothing);
    expect(
      find.byKey(const ValueKey('conversation-model-select')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
