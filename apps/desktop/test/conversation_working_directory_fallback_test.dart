import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';

void main() {
  AgentConversationSession session({
    required String id,
    required String updatedAt,
    String workingDirectory = '',
  }) {
    return AgentConversationSession(
      id: id,
      agentId: 'cursor',
      title: id,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      messages: const [],
      workingDirectory: workingDirectory,
    );
  }

  test('historical cwd prefers the newest usable project path', () {
    final home = userHomeDirectory();
    expect(home, isNotEmpty);

    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'old',
        updatedAt: '2026-01-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/older-project',
      ),
      session(
        id: 'home',
        updatedAt: '2026-06-01T00:00:00Z',
        workingDirectory: home,
      ),
      session(
        id: 'recent',
        updatedAt: '2026-05-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/recent-project',
      ),
      session(id: 'empty', updatedAt: '2026-07-01T00:00:00Z'),
    ]);

    expect(chosen, '/synthetic/workspaces/recent-project');
  });

  test('historical cwd is empty when only unbounded roots exist', () {
    final home = userHomeDirectory();
    expect(home, isNotEmpty);

    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'home',
        updatedAt: '2026-06-01T00:00:00Z',
        workingDirectory: home,
      ),
    ]);

    expect(chosen, isEmpty);
  });

  test('historical cwd skips the client-owned agent-workspaces fallback', () {
    final fallback = localConversationWorkingDirectoryFallback(
      agentId: 'cursor',
    );
    expect(fallback, isNotEmpty);
    expect(isClientOwnedAgentWorkspace(fallback), isTrue);
    expect(isUsableLocalConversationWorkingDirectory(fallback), isFalse);

    final chosen = historicalConversationWorkingDirectory([
      session(
        id: 'fallback',
        updatedAt: '2026-07-01T00:00:00Z',
        workingDirectory: fallback,
      ),
      session(
        id: 'project',
        updatedAt: '2026-05-01T00:00:00Z',
        workingDirectory: '/synthetic/workspaces/real-project',
      ),
    ]);

    expect(chosen, '/synthetic/workspaces/real-project');
  });
}
