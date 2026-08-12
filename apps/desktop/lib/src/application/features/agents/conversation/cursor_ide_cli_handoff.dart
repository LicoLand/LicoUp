import 'package:licoup/src/contracts/agent_conversation_models.dart';

/// Bounded last-assistant excerpt injected into the first CLI turn that
/// continues a Cursor IDE history row (IDE and CLI stores do not resume).
const int cursorIdeCliHandoffAssistantCapChars = 8000;

const Set<String> cursorIdeHistorySourceKinds = <String>{
  'cursor-global-storage',
  'cursor-workspace-storage',
};

/// True when [session] is a Cursor IDE composer/history row (not Agent CLI).
bool isCursorIdeHistorySession(AgentConversationSession? session) {
  if (session == null) return false;
  return cursorIdeHistorySourceKinds.contains(session.sourceKind.trim());
}

/// Newest non-empty assistant/agent return text, capped for prompt injection.
String lastAssistantReturnText(
  AgentConversationSession session, {
  int maxChars = cursorIdeCliHandoffAssistantCapChars,
}) {
  final thread = session.threadMessages;
  for (var index = thread.length - 1; index >= 0; index -= 1) {
    final message = thread[index];
    if (message.kind != AgentConversationMessageKind.assistant) continue;
    final text = message.text.trim();
    if (text.isEmpty) continue;
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n…[truncated]';
  }
  return '';
}

/// Whether this Cursor 1:1 send should inject a one-time IDE→CLI handoff.
bool shouldInjectCursorIdeCliHandoff({
  required String agentId,
  required AgentConversationSession? session,
  required Set<String> handedOffComposerIds,
}) {
  if (agentId.trim() != 'cursor') return false;
  if (!isCursorIdeHistorySession(session)) return false;
  final composerId = session!.nativeSessionId.trim();
  if (composerId.isEmpty) return false;
  return !handedOffComposerIds.contains(composerId);
}

/// Builds the outbound CLI prompt: IDE metadata + last assistant return + user.
String buildIdeToCliHandoffPrompt({
  required AgentConversationSession session,
  required String userText,
  int maxAssistantChars = cursorIdeCliHandoffAssistantCapChars,
}) {
  final composerId = session.nativeSessionId.trim();
  final lastAssistant = lastAssistantReturnText(
    session,
    maxChars: maxAssistantChars,
  );
  final assistantBlock = lastAssistant.isEmpty ? '(empty)' : lastAssistant;
  return [
    '[LicoUp IDE→CLI handoff — once]',
    'composerSessionId: $composerId',
    'stateVscdbPath: ${session.sourcePath.trim()}',
    'sqliteTable: cursorDiskKV',
    'keyPrefixes: composerData:$composerId ; bubbleId:$composerId:',
    'sourceKind: ${session.sourceKind.trim()}',
    '',
    '--- last IDE assistant return ---',
    assistantBlock,
    '',
    '--- user message ---',
    userText.trim(),
  ].join('\n');
}
