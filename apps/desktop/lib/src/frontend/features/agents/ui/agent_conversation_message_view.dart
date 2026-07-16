import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/agent_conversation_models.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_event_card.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_message_blocks.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentConversationMessageList extends StatefulWidget {
  const AgentConversationMessageList({
    super.key,
    required this.loading,
    required this.session,
    required this.target,
    this.turnActive = false,
    this.liveMessages = const [],
  });

  final bool loading;
  final AgentConversationSession? session;
  final TargetCandidate target;
  final bool turnActive;
  final List<AgentConversationMessage> liveMessages;

  @override
  State<AgentConversationMessageList> createState() =>
      AgentConversationMessageListState();
}

class AgentConversationMessageListState
    extends State<AgentConversationMessageList> {
  bool _showDiagnostics = false;
  late Future<AgentRenderAdapter> _adapterFuture;
  (AgentRenderAdapterRegistry, String, String, String, String)?
  _adapterResolutionKey;
  AgentConversationSession? _timelineSession;
  List<AgentConversationMessage>? _timelineLiveMessages;
  String _timelineSessionIdentity = '';
  String _timelineSessionKey = '';
  List<ConversationTimelineItem> _timelineItems = const [];
  Map<String, int> _timelineIndexByStorageKey = const {};
  List<AgentSemanticArtifactRef> _artifacts = const [];
  int _footerCount = 0;
  String _activeProcessStorageKey = '';

  @override
  void initState() {
    super.initState();
    _syncAdapterFuture();
    _syncTimelineCache();
    _syncActiveProcessStorageKey();
  }

  @override
  void didUpdateWidget(covariant AgentConversationMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAdapterFuture();
    final timelineChanged = _syncTimelineCache();
    if (timelineChanged || oldWidget.turnActive != widget.turnActive) {
      _syncActiveProcessStorageKey();
    }
  }

  void _syncAdapterFuture() {
    final registry = AgentRenderAdapterRegistry.instance;
    final session = widget.session;
    final nextKey = (
      registry,
      widget.target.target,
      session?.sourceClient ?? '',
      session?.sourceTool ?? '',
      session?.adapterId ?? '',
    );
    if (_adapterResolutionKey == nextKey) {
      return;
    }
    _adapterResolutionKey = nextKey;
    _adapterFuture = registry.resolve(
      agentId: nextKey.$2,
      sourceClient: nextKey.$3,
      sourceTool: nextKey.$4,
      adapterId: nextKey.$5,
    );
  }

  bool _syncTimelineCache() {
    final session = widget.session;
    final sessionIdentity = [
      widget.target.target,
      session?.id ?? '',
      session?.nativeSessionId ?? '',
    ].join('|');
    if (identical(_timelineSession, session) &&
        identical(_timelineLiveMessages, widget.liveMessages) &&
        _timelineSessionIdentity == sessionIdentity) {
      return false;
    }

    final messages = <AgentConversationMessage>[
      ...?session?.messages,
      ...widget.liveMessages,
    ];
    final timelineItems = buildConversationTimelineItems(
      messages,
      sessionIdentity,
      historyTruncated: session?.historyTruncated ?? false,
      messageTreeTruncated: session?.messageTreeTruncated ?? false,
    ).reversed.toList(growable: false);
    final artifacts = session?.artifacts ?? const <AgentSemanticArtifactRef>[];
    final hasDiagnostics = session?.hasDiagnostics ?? false;
    final footerCount =
        (artifacts.isNotEmpty ? 1 : 0) + (hasDiagnostics ? 1 : 0);
    final indexByStorageKey = <String, int>{};
    var footerIndex = 0;
    if (hasDiagnostics) {
      indexByStorageKey['conversation-diagnostics'] = footerIndex;
      footerIndex += 1;
    }
    if (artifacts.isNotEmpty) {
      indexByStorageKey['conversation-artifacts'] = footerIndex;
    }
    for (var index = 0; index < timelineItems.length; index += 1) {
      indexByStorageKey[timelineItems[index].storageKey] = index + footerCount;
    }

    _timelineSession = session;
    _timelineLiveMessages = widget.liveMessages;
    _timelineSessionIdentity = sessionIdentity;
    _timelineSessionKey = sessionIdentity.hashCode
        .toUnsigned(32)
        .toRadixString(16);
    _timelineItems = timelineItems;
    _timelineIndexByStorageKey = Map<String, int>.unmodifiable(
      indexByStorageKey,
    );
    _artifacts = artifacts;
    _footerCount = footerCount;
    return true;
  }

  void _syncActiveProcessStorageKey() {
    _activeProcessStorageKey = '';
    if (!widget.turnActive) {
      return;
    }
    for (final item in _timelineItems) {
      if (item is ConversationProcessTimelineItem) {
        _activeProcessStorageKey = item.storageKey;
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final session = widget.session;
    final messages = <AgentConversationMessage>[
      ...?session?.messages,
      ...widget.liveMessages,
    ];
    if (widget.loading && messages.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            strings.noMessagesInHistory,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted),
          ),
        ),
      );
    }
    return FutureBuilder<AgentRenderAdapter>(
      future: _adapterFuture,
      builder: (context, snapshot) {
        final adapter = snapshot.data ?? AgentRenderAdapter.fallback();
        return ListView.builder(
          key: PageStorageKey<String>(
            'agent-conversation-message-list-$_timelineSessionKey',
          ),
          reverse: true,
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + adapter.assistantVerticalPadding,
          ),
          findChildIndexCallback: (key) {
            if (key case ValueKey<String>(:final value)) {
              return _timelineIndexByStorageKey[value];
            }
            return null;
          },
          itemBuilder: (context, index) {
            if (index < _footerCount) {
              if (session?.hasDiagnostics ?? false) {
                if (index == 0) {
                  return Padding(
                    key: const ValueKey<String>('conversation-diagnostics'),
                    padding: EdgeInsets.only(
                      bottom: adapter.assistantVerticalPadding,
                    ),
                    child: _ConversationDiagnosticsPanel(
                      session: session!,
                      expanded: _showDiagnostics,
                      onToggle: () {
                        setState(() {
                          _showDiagnostics = !_showDiagnostics;
                        });
                      },
                    ),
                  );
                }
                if (_artifacts.isNotEmpty && index == 1) {
                  return Padding(
                    key: const ValueKey<String>('conversation-artifacts'),
                    padding: EdgeInsets.only(
                      bottom: adapter.assistantVerticalPadding,
                    ),
                    child: _ConversationArtifactsPanel(artifacts: _artifacts),
                  );
                }
              } else if (_artifacts.isNotEmpty && index == 0) {
                return Padding(
                  key: const ValueKey<String>('conversation-artifacts'),
                  padding: EdgeInsets.only(
                    bottom: adapter.assistantVerticalPadding,
                  ),
                  child: _ConversationArtifactsPanel(artifacts: _artifacts),
                );
              }
            }
            final item = _timelineItems[index - _footerCount];
            final content = switch (item) {
              ConversationMessageTimelineItem(:final message) =>
                AgentConversationMessageBlock(
                  message: message,
                  adapter: adapter,
                ),
              ConversationProcessTimelineItem(:final events) =>
                ConversationProcessCard(
                  events: events,
                  adapter: adapter,
                  detailsBuilder: buildAgentConversationEventDetails,
                  active: item.storageKey == _activeProcessStorageKey,
                ),
              ConversationTruncationTimelineItem(
                :final historyTruncated,
                :final messageTreeTruncated,
              ) =>
                ConversationTruncationNotice(
                  historyTruncated: historyTruncated,
                  messageTreeTruncated: messageTreeTruncated,
                ),
            };
            return Padding(
              key: ValueKey<String>(item.storageKey),
              padding: EdgeInsets.only(
                bottom: index + 1 < _timelineItems.length + _footerCount
                    ? adapter.assistantVerticalPadding
                    : 0,
              ),
              child: content,
            );
          },
          itemCount: _timelineItems.length + _footerCount,
        );
      },
    );
  }
}

class _ConversationArtifactsPanel extends StatelessWidget {
  const _ConversationArtifactsPanel({required this.artifacts});

  final List<AgentSemanticArtifactRef> artifacts;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line.withAlpha(80)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Artifacts', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final artifact in artifacts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${artifact.label} (${artifact.kind})'
                  '${artifact.ref.isEmpty ? '' : ' → ${artifact.ref}'}',
                  style: TextStyle(color: colors.textMuted, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConversationDiagnosticsPanel extends StatelessWidget {
  const _ConversationDiagnosticsPanel({
    required this.session,
    required this.expanded,
    required this.onToggle,
  });

  final AgentConversationSession session;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final semantic = session.semantic;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.line.withAlpha(80)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Diagnostics',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: colors.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (expanded && semantic != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Audit',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Adapter: ${semantic.audit.adapterId}\n'
                    'Host: ${semantic.audit.hostApp}\n'
                    'Source: ${semantic.audit.sourceKind}\n'
                    'Session: ${semantic.audit.nativeSessionId}\n'
                    'Redaction: ${semantic.audit.redactionStatus}\n'
                    'Validation: ${semantic.audit.validationStatus}\n'
                    'Evidence: ${semantic.audit.sourceEvidence.pathRef}',
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                  if (semantic.audit.parseWarnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Parse warnings: ${semantic.audit.parseWarnings.join('; ')}',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Raw evidence',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  for (final evidence in semantic.rawEvidence)
                    Text(
                      '${evidence.kind}: ${evidence.pathRef} (${evidence.contentHash})',
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
