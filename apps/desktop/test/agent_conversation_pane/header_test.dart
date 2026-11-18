import 'pane_test_harness.dart';

void main() {
  testWidgets('header owns session identity and collapse control', (
    tester,
  ) async {
    var toggleCount = 0;
    const session = AgentConversationSession(
      id: 'session-1',
      agentId: 'codex',
      title: 'Focused session',
      createdAt: '2026-07-16T00:00:00Z',
      updatedAt: '2026-07-16T00:00:00Z',
      messages: [],
    );
    await tester.pumpWidget(
      paneTestApp(
        paneTestHeader(
          session: session,
          onToggleHistory: () => toggleCount += 1,
        ),
      ),
    );

    expect(find.text('Focused session'), findsOneWidget);
    final toggle = find.byTooltip('Collapse history');
    expect(toggle, findsOneWidget);
    expect(
      tester.getTopLeft(toggle).dx,
      lessThan(tester.getTopLeft(find.text('Focused session')).dx),
    );
    await tester.tap(toggle);
    await tester.pump();
    expect(toggleCount, 1);
  });

  testWidgets('header discloses the exact SSH VM conversation destination', (
    tester,
  ) async {
    final workingDirectory = _guestPath(['srv', 'project']);
    final target = paneTestTarget(
      target: 'hermes',
      label: 'Hermes',
      location: 'virtual-machine',
      binaryPath: 'hermes',
      runtimeConnection: {
        'kind': 'ssh',
        'host': 'vm.example',
        'port': 2222,
        'user': 'agent-user',
        'remoteExecutable': 'hermes',
        'workingDirectory': workingDirectory,
      },
    );

    await tester.pumpWidget(paneTestApp(paneTestHeader(target: target)));

    expect(
      find.byKey(const Key('conversation-virtual-machine-destination')),
      findsOneWidget,
    );
    expect(find.text('SSH · agent-user@vm.example:2222'), findsOneWidget);
    expect(
      find.byTooltip(
        'Virtual machine conversation destination: agent-user@vm.example:2222',
      ),
      findsOneWidget,
    );
  });
}

String _guestPath(List<String> segments) => ['', ...segments].join('/');
