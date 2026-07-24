import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:flutter/material.dart';
export 'package:licoup/src/contracts/agent_conversation_models.dart';
export 'package:licoup/src/contracts/target_candidate.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane.dart';
export 'package:flutter_test/flutter_test.dart';

AgentConversationPaneState paneTestState({
  AgentConversationSession? session,
  List<AgentConversationMessage> liveMessages = const [],
  List<AgentConversationSession> recentSessions = const [],
  bool preparingNewConversation = false,
  bool? turnActive,
  String sendGateReasonCode = '',
}) => AgentConversationPaneState(
  target: paneTestTarget(),
  session: session,
  liveMessages: liveMessages,
  recentSessions: recentSessions,
  loading: false,
  turnActive: turnActive ?? liveMessages.isNotEmpty,
  preparingNewConversation: preparingNewConversation,
  orchestrationSelected: false,
  composerEnabled: true,
  sendGateReasonCode: sendGateReasonCode,
  composerDraft: '',
  modelOptions: const [],
  selectedModel: '',
  defaultModel: '',
  reasoningEffortOptions: const [],
  selectedReasoningEffort: '',
);

AgentConversationPaneActions paneTestActions() => AgentConversationPaneActions(
  onModelChanged: (_) {},
  onReasoningEffortChanged: (_) {},
  onDraftChanged: (_) {},
  onSend: (_) async => true,
  onSelectSession: (_) {},
);

ConversationPaneHeader paneTestHeader({
  AgentConversationSession? session,
  VoidCallback? onToggleHistory,
}) => ConversationPaneHeader(
  state: AgentConversationHeaderState(
    target: paneTestTarget(),
    session: session,
    historyCollapsed: false,
    collapseHistoryTooltip: 'Collapse history',
    expandHistoryTooltip: 'Expand history',
    orchestrationSelected: false,
    opencodeServeState: null,
  ),
  actions: AgentConversationHeaderActions(
    onToggleHistory: onToggleHistory ?? () {},
  ),
);

TargetCandidate paneTestTarget({
  String target = 'codex',
  String label = 'Codex',
}) => TargetCandidate(
  target: target,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationReadiness': 'ready'},
  supportedActions: const ['runtime.message.send'],
);

Widget paneTestApp(Widget child, {double width = 800, double height = 600}) {
  return MaterialApp(
    locale: const Locale('en'),
    theme: buildLicoTheme(
      platformBrightness: Brightness.dark,
    ).copyWith(platform: TargetPlatform.macOS),
    home: Scaffold(
      body: SizedBox(width: width, height: height, child: child),
    ),
  );
}
