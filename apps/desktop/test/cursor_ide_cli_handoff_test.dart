import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/conversation/cursor_ide_cli_handoff.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';

void main() {
  AgentConversationSession session({
    String sourceKind = 'cursor-global-storage',
    String nativeSessionId = 'composer-1',
    String sourcePath = '/fixture/location/state.vscdb',
    List<AgentConversationMessage> messages = const [],
  }) {
    return AgentConversationSession(
      id: 'cursor|$nativeSessionId',
      agentId: 'cursor',
      title: 'IDE chat',
      createdAt: '2026-08-06T00:00:00Z',
      updatedAt: '2026-08-06T00:00:00Z',
      messages: messages,
      nativeSessionId: nativeSessionId,
      sourceKind: sourceKind,
      sourcePath: sourcePath,
    );
  }

  test('detects IDE history source kinds only', () {
    expect(
      isCursorIdeHistorySession(session(sourceKind: 'cursor-global-storage')),
      isTrue,
    );
    expect(
      isCursorIdeHistorySession(
        session(sourceKind: 'cursor-workspace-storage'),
      ),
      isTrue,
    );
    expect(
      isCursorIdeHistorySession(session(sourceKind: 'cursor-cli-projects')),
      isFalse,
    );
    expect(isCursorIdeHistorySession(null), isFalse);
  });

  test('picks the newest non-empty assistant return and caps length', () {
    final long = 'A' * (cursorIdeCliHandoffAssistantCapChars + 20);
    final text = lastAssistantReturnText(
      session(
        messages: [
          const AgentConversationMessage(
            id: 'u1',
            role: 'user',
            text: 'first',
            createdAt: '2026-08-06T00:00:00Z',
          ),
          const AgentConversationMessage(
            id: 'a1',
            role: 'assistant',
            text: 'older reply',
            createdAt: '2026-08-06T00:00:01Z',
          ),
          AgentConversationMessage(
            id: 'a2',
            role: 'assistant',
            text: long,
            createdAt: '2026-08-06T00:00:02Z',
          ),
        ],
      ),
    );
    expect(text.startsWith('A' * 32), isTrue);
    expect(text.endsWith('…[truncated]'), isTrue);
    expect(text.length, lessThan(long.length));
  });

  test('builds handoff prompt with metadata and user text', () {
    final prompt = buildIdeToCliHandoffPrompt(
      session: session(
        messages: const [
          AgentConversationMessage(
            id: 'a1',
            role: 'assistant',
            text: 'Last IDE return about quota fallback.',
            createdAt: '2026-08-06T00:00:01Z',
          ),
        ],
      ),
      userText: 'Continue from IDE',
    );
    expect(prompt, contains('[LicoUp IDE→CLI handoff — once]'));
    expect(prompt, contains('composerSessionId: composer-1'));
    expect(prompt, contains('stateVscdbPath: /fixture/location/state.vscdb'));
    expect(prompt, contains('sqliteTable: cursorDiskKV'));
    expect(prompt, contains('keyPrefixes: composerData:composer-1'));
    expect(prompt, contains('Last IDE return about quota fallback.'));
    expect(prompt, contains('--- user message ---'));
    expect(prompt, contains('Continue from IDE'));
  });

  test('shouldInject requires cursor agent, IDE kind, and unused composer id', () {
    final ide = session();
    expect(
      shouldInjectCursorIdeCliHandoff(
        agentId: 'cursor',
        session: ide,
        handedOffComposerIds: const {},
      ),
      isTrue,
    );
    expect(
      shouldInjectCursorIdeCliHandoff(
        agentId: 'codex',
        session: ide,
        handedOffComposerIds: const {},
      ),
      isFalse,
    );
    expect(
      shouldInjectCursorIdeCliHandoff(
        agentId: 'cursor',
        session: session(sourceKind: 'cursor-cli-projects'),
        handedOffComposerIds: const {},
      ),
      isFalse,
    );
    expect(
      shouldInjectCursorIdeCliHandoff(
        agentId: 'cursor',
        session: ide,
        handedOffComposerIds: const {'composer-1'},
      ),
      isFalse,
    );
  });
}
