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
export 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
export 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
export 'package:flutter_test/flutter_test.dart';

AgentConversationPaneState paneTestState({
  AgentConversationSession? session,
  List<AgentConversationMessage> liveMessages = const [],
  List<AgentConversationSession> recentSessions = const [],
  bool preparingNewConversation = false,
  bool loading = false,
  bool? turnActive,
  String sendGateReasonCode = '',
  bool showWorkingDirectory = false,
  String workingDirectory = '',
  bool workingDirectorySelectable = false,
  List<String> modelOptions = const [],
  String selectedModel = '',
  String defaultModel = '',
  bool sendAuthorizeActive = false,
  bool recentSessionsCached = false,
}) => AgentConversationPaneState(
  target: paneTestTarget(),
  session: session,
  liveMessages: liveMessages,
  recentSessions: recentSessions,
  loading: loading,
  turnActive: turnActive ?? liveMessages.isNotEmpty,
  preparingNewConversation: preparingNewConversation,
  composerEnabled: true,
  sendGateReasonCode: sendGateReasonCode,
  composerDraft: '',
  modelOptions: modelOptions,
  selectedModel: selectedModel,
  defaultModel: defaultModel,
  reasoningEffortOptions: const [],
  selectedReasoningEffort: '',
  showWorkingDirectory: showWorkingDirectory,
  workingDirectory: workingDirectory,
  workingDirectorySelectable: workingDirectorySelectable,
  sendAuthorizeActive: sendAuthorizeActive,
  recentSessionsCached: recentSessionsCached,
);

AgentConversationPaneActions paneTestActions({
  VoidCallback? onChooseWorkingDirectory,
  VoidCallback? onUnblockSend,
  ValueChanged<String>? onModelChanged,
}) => AgentConversationPaneActions(
  onModelChanged: onModelChanged ?? (_) {},
  onReasoningEffortChanged: (_) {},
  onDraftChanged: (_) {},
  onSend: (_) async => true,
  onSelectSession: (_) {},
  onUnblockSend: onUnblockSend,
  onChooseWorkingDirectory: onChooseWorkingDirectory,
);

ConversationPaneHeader paneTestHeader({
  AgentConversationSession? session,
  VoidCallback? onToggleHistory,
  TargetCandidate? target,
}) => ConversationPaneHeader(
  state: AgentConversationHeaderState(
    target: target ?? paneTestTarget(),
    session: session,
    historyCollapsed: false,
    collapseHistoryTooltip: 'Collapse history',
    expandHistoryTooltip: 'Expand history',
    opencodeServeState: null,
  ),
  actions: AgentConversationHeaderActions(
    onToggleHistory: onToggleHistory ?? () {},
  ),
);

TargetCandidate paneTestTarget({
  String target = 'codex',
  String label = 'Codex',
  String location = 'local',
  String? binaryPath,
  Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
}) => TargetCandidate(
  target: target,
  label: label,
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: binaryPath,
  adapterStatus: 'implemented',
  adapterCapabilities: const {
    'conversationReadiness': 'ready',
    'conversationDriver': 'implemented',
  },
  supportedActions: const ['runtime.message.send'],
  location: location,
  runtimeConnection: runtimeConnection,
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
