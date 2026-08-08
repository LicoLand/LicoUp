import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_update_card.dart';

import 'agent_conversation_message_blocks/message_blocks_test_harness.dart';

AgentConversationMessage _updateMessage({
  required String text,
  required String subtitle,
}) {
  return AgentConversationMessage(
    id: 'turn-runtime-update',
    role: 'event',
    text: text,
    createdAt: '2030-01-01T00:00:00Z',
    cardType: 'runtime-update',
    cardTitle: 'runtime.update',
    cardSubtitle: subtitle,
    stableIdentity: 'turn-runtime-update',
  );
}

void main() {
  testWidgets('active update card shows indeterminate progress and title', (
    tester,
  ) async {
    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentRuntimeUpdateCard(
          message: _updateMessage(
            text: 'downloading',
            subtitle: 'Cursor Agent 正在更新 2026.08.04-aaa8809 · 下载中',
          ),
          adapter: AgentRenderAdapter.fallback(),
          active: true,
        ),
      ),
    );
    expect(find.text('Cursor Agent is updating automatically'), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime-update-progress')), findsOneWidget);
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('runtime-update-progress')),
    );
    // Indeterminate on purpose: no vendor signal exposes a real percentage.
    expect(indicator.value, isNull);
  });

  testWidgets('completed update card swaps to check icon and drops the bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentRuntimeUpdateCard(
          message: _updateMessage(
            text: 'completed',
            subtitle: 'Cursor Agent 更新完成 · 2026.08.04-aaa8809',
          ),
          adapter: AgentRenderAdapter.fallback(),
        ),
      ),
    );
    expect(find.text('Update completed'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime-update-progress')), findsNothing);
  });

  testWidgets('interrupted update card shows error icon and hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      messageBlocksTestApp(
        AgentRuntimeUpdateCard(
          message: _updateMessage(
            text: 'interrupted',
            subtitle: 'Cursor Agent 更新中断 · 已清理过期安装锁',
          ),
          adapter: AgentRenderAdapter.fallback(),
        ),
      ),
    );
    expect(find.text('Update interrupted'), findsOneWidget);
    expect(find.byIcon(Icons.error_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime-update-progress')), findsNothing);
  });
}
