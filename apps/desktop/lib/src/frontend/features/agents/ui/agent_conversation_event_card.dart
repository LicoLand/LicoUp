part of 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_workspace.dart';

sealed class _ConversationTimelineItem {
  const _ConversationTimelineItem(this.storageKey);

  final String storageKey;
}

final class _ConversationMessageTimelineItem extends _ConversationTimelineItem {
  const _ConversationMessageTimelineItem(super.storageKey, this.message);

  final AgentConversationMessage message;
}

final class _ConversationProcessTimelineItem extends _ConversationTimelineItem {
  const _ConversationProcessTimelineItem(super.storageKey, this.events);

  final List<AgentConversationMessage> events;
}

final class _ConversationTruncationTimelineItem
    extends _ConversationTimelineItem {
  const _ConversationTruncationTimelineItem(
    super.storageKey, {
    required this.historyTruncated,
    required this.messageTreeTruncated,
  });

  final bool historyTruncated;
  final bool messageTreeTruncated;
}

List<_ConversationTimelineItem> _conversationTimelineItems(
  List<AgentConversationMessage> messages,
  String sessionScope, {
  bool historyTruncated = false,
  bool messageTreeTruncated = false,
}) {
  final items = <_ConversationTimelineItem>[];
  final usedStorageKeys = <String>{};
  var pendingEvents = <AgentConversationMessage>[];
  var processAnchor = 'session-start';
  var messageIndex = 0;

  String messageIdentity(AgentConversationMessage message, int sourceIndex) {
    if (message.stableIdentity.trim().isNotEmpty) {
      return message.stableIdentity.trim();
    }
    final immutableIdentity = [
      message.id.trim(),
      message.createdAt,
      message.role,
      message.cardType,
    ].join('|');
    return immutableIdentity.replaceAll('|', '').isNotEmpty
        ? _stableTimelineIdentity(immutableIdentity)
        : 'position-$sourceIndex';
  }

  String stableStorageKey(
    String kind,
    String sourceIdentity, {
    int collisionPosition = 0,
  }) {
    final base =
        'conversation-timeline-$kind-${_stableTimelineIdentity('$sessionScope|$kind|$sourceIdentity')}';
    if (usedStorageKeys.add(base)) {
      return base;
    }
    final disambiguated =
        '$base-${_stableTimelineIdentity('$sourceIdentity|$collisionPosition')}';
    usedStorageKeys.add(disambiguated);
    return disambiguated;
  }

  if (historyTruncated || messageTreeTruncated) {
    items.add(
      _ConversationTruncationTimelineItem(
        stableStorageKey('truncation', 'source-boundary'),
        historyTruncated: historyTruncated,
        messageTreeTruncated: messageTreeTruncated,
      ),
    );
  }

  void flushEvents() {
    if (pendingEvents.isEmpty) {
      return;
    }
    items.add(
      _ConversationProcessTimelineItem(
        stableStorageKey(
          'process',
          processAnchor,
          collisionPosition: messageIndex,
        ),
        List<AgentConversationMessage>.unmodifiable(pendingEvents),
      ),
    );
    pendingEvents = <AgentConversationMessage>[];
  }

  for (final message in messages) {
    if (message.isStructuredEvent) {
      pendingEvents.add(message);
      continue;
    }
    flushEvents();
    final identity = messageIdentity(message, messageIndex);
    items.add(
      _ConversationMessageTimelineItem(
        stableStorageKey('message', identity, collisionPosition: messageIndex),
        message,
      ),
    );
    processAnchor = identity;
    messageIndex += 1;
  }
  flushEvents();
  return List<_ConversationTimelineItem>.unmodifiable(items);
}

String _stableTimelineIdentity(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toUnsigned(32).toRadixString(16).padLeft(8, '0');
}

class _ConversationTruncationNotice extends StatelessWidget {
  const _ConversationTruncationNotice({
    required this.historyTruncated,
    required this.messageTreeTruncated,
  });

  final bool historyTruncated;
  final bool messageTreeTruncated;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final message = historyTruncated && messageTreeTruncated
        ? strings.conversationHistoryAndDetailsTruncated
        : historyTruncated
        ? strings.conversationHistoryTruncated
        : strings.conversationDetailsTruncated;
    return Semantics(
      container: true,
      label: message,
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: colors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationProcessCard extends StatefulWidget {
  const _ConversationProcessCard({
    required this.events,
    required this.adapter,
    this.active = false,
  }) : assert(events.length > 0);

  final List<AgentConversationMessage> events;
  final AgentRenderAdapter adapter;
  final bool active;

  @override
  State<_ConversationProcessCard> createState() =>
      _ConversationProcessCardState();
}

class _ConversationProcessCardState extends State<_ConversationProcessCard> {
  final FocusNode _headerFocusNode = FocusNode(
    debugLabel: 'conversation-process-header',
  );
  bool _expanded = false;
  bool _focused = false;

  String get _processId => widget.events.first.id;

  @override
  void dispose() {
    _headerFocusNode.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    final expanding = !_expanded;
    setState(() => _expanded = expanding);
    if (!expanding) {
      return;
    }
    final delay = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 210);
    void scheduleEnsureVisible() {
      if (!mounted || !_expanded) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_expanded) {
          return;
        }
        final headerContext = _headerFocusNode.context;
        if (headerContext == null || !headerContext.mounted) {
          return;
        }
        Scrollable.ensureVisible(
          headerContext,
          alignment: 0.08,
          duration: Duration.zero,
        );
      });
      WidgetsBinding.instance.scheduleFrame();
    }

    if (delay == Duration.zero) {
      scheduleEnsureVisible();
    } else {
      Future<void>.delayed(delay, scheduleEnsureVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final flattened = _flattenProcessEvents(widget.events);
    final operations = flattened.events;
    final title = _processTitle(
      flattened.startedAt,
      flattened.endedAt,
      strings,
    );
    final summary = _processSummary(
      flattened.totalOperations,
      flattened.issues,
      flattened.countTruncated,
      strings,
    );
    final motionDisabled = MediaQuery.disableAnimationsOf(context);
    final containerDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final sizeDuration = motionDisabled
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final actionHint = _expanded
        ? strings.collapseProcessDetails
        : strings.expandProcessDetails;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.adapter.assistantMaxWidth),
        child: AnimatedContainer(
          key: ValueKey('conversation-process-$_processId'),
          duration: containerDuration,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: _expanded
                ? Colors.white.withAlpha(colors.isDark ? 22 : 28)
                : Colors.white.withAlpha(colors.isDark ? 14 : 18),
            borderRadius: BorderRadius.circular(
              AppleControlMetrics.menuCornerRadius,
            ),
            border: Border.all(
              color: _focused
                  ? colors.info.withAlpha(170)
                  : Colors.white.withAlpha(colors.isDark ? 42 : 64),
              width: AppleControlMetrics.hairline,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  key: ValueKey('conversation-process-semantics-$_processId'),
                  container: true,
                  button: true,
                  focusable: true,
                  focused: _focused,
                  expanded: _expanded,
                  label: '${strings.agentProcess}. $title. $summary.',
                  hint: actionHint,
                  onTap: _toggleExpanded,
                  child: ExcludeSemantics(
                    child: Tooltip(
                      message: actionHint,
                      child: InkWell(
                        key: ValueKey(
                          'conversation-process-toggle-$_processId',
                        ),
                        focusNode: _headerFocusNode,
                        onFocusChange: (focused) {
                          if (_focused != focused) {
                            setState(() => _focused = focused);
                          }
                        },
                        onTap: _toggleExpanded,
                        focusColor: colors.info.withValues(alpha: 0.10),
                        hoverColor: colors.text.withValues(alpha: 0.04),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                widget.active
                                    ? LicoSpinningRefreshIcon(
                                        size: 15,
                                        color: colors.textMuted,
                                      )
                                    : Icon(
                                        Icons.format_list_bulleted_rounded,
                                        size: 16,
                                        color: colors.textMuted,
                                      ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      LicoShimmerText(
                                        text: title,
                                        enabled: widget.active,
                                        style: TextStyle(
                                          color: colors.text,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: -0.08,
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      LicoShimmerText(
                                        text: summary,
                                        enabled: widget.active,
                                        style: TextStyle(
                                          color: colors.textMuted,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w400,
                                          letterSpacing: -0.04,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                AnimatedRotation(
                                  turns: _expanded ? 0.5 : 0,
                                  duration: containerDuration,
                                  curve: Curves.easeOutCubic,
                                  child: Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    size: 18,
                                    color: colors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (motionDisabled)
                  _expanded
                      ? _ProcessOperationList(
                          operations: operations,
                          adapter: widget.adapter,
                          truncated: flattened.renderTruncated,
                          activeStepIndex: widget.active
                              ? operations.length - 1
                              : -1,
                        )
                      : const SizedBox.shrink()
                else
                  AnimatedSize(
                    duration: sizeDuration,
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _expanded
                        ? _ProcessOperationList(
                            operations: operations,
                            adapter: widget.adapter,
                            truncated: flattened.renderTruncated,
                            activeStepIndex: widget.active
                                ? operations.length - 1
                                : -1,
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProcessOperationList extends StatelessWidget {
  const _ProcessOperationList({
    required this.operations,
    required this.adapter,
    required this.truncated,
    this.activeStepIndex = -1,
  });

  final List<AgentConversationMessage> operations;
  final AgentRenderAdapter adapter;
  final bool truncated;
  final int activeStepIndex;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final operationKeys = _uniqueProcessOperationKeys(operations);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < operations.length; index++) ...[
            if (index > 0) Divider(height: 1, indent: 46, color: colors.line),
            _ProcessOperationRow(
              message: operations[index],
              adapter: adapter,
              operationKey: operationKeys[index],
              executing: index == activeStepIndex,
            ),
          ],
          if (truncated) ...[
            if (operations.isNotEmpty)
              Divider(height: 1, indent: 46, color: colors.line),
            const _ProcessTruncationRow(),
          ],
        ],
      ),
    );
  }
}

class _ProcessTruncationRow extends StatelessWidget {
  const _ProcessTruncationRow();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.more_horiz_rounded, size: 17, color: colors.textMuted),
            const SizedBox(width: 15),
            Expanded(
              child: Text(
                strings.additionalOperationsHidden,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProcessOperationRow extends StatelessWidget {
  const _ProcessOperationRow({
    required this.message,
    required this.adapter,
    required this.operationKey,
    this.executing = false,
  });

  final AgentConversationMessage message;
  final AgentRenderAdapter adapter;
  final String operationKey;
  final bool executing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final presentation = _eventPresentation(message.kind, colors, strings);
    final defaultReasoningTitle =
        message.kind == AgentConversationMessageKind.reasoning &&
        message.providerSummary;
    final rawTitle = message.cardTitle.trim();
    final title =
        rawTitle.isEmpty ||
            defaultReasoningTitle ||
            _isDefaultProcessTitle(message.kind, rawTitle)
        ? (defaultReasoningTitle
              ? strings.reasoningSummary
              : presentation.title)
        : rawTitle;
    final rawSubtitle = message.cardSubtitle.trim();
    final subtitle = defaultReasoningTitle
        ? strings.providerSummary
        : rawSubtitle.isEmpty || _isDefaultProcessSubtitle(rawSubtitle)
        ? presentation.subtitle
        : rawSubtitle;
    final details = message.text.trim().isNotEmpty
        ? message.text.trim()
        : _localizedHiddenProcessDetails(message.kind, strings);
    final mutedDetails =
        message.kind == AgentConversationMessageKind.metadata ||
        message.kind == AgentConversationMessageKind.toolCall ||
        (message.kind == AgentConversationMessageKind.reasoning &&
            !message.providerSummary);

    return Semantics(
      key: ValueKey('conversation-process-operation-$operationKey'),
      container: true,
      label: '$title. $subtitle. $details',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: executing
                        ? LicoSpinningRefreshIcon(
                            size: 15,
                            color: presentation.accent,
                          )
                        : Icon(
                            presentation.icon,
                            size: 17,
                            color: presentation.accent,
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LicoShimmerText(
                        text: title,
                        enabled: executing,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle.isNotEmpty)
                        LicoShimmerText(
                          text: subtitle,
                          enabled: executing,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      if (details.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        _MessageContent(
                          data: details,
                          foreground: mutedDetails
                              ? colors.textMuted
                              : colors.text,
                          accent: presentation.accent,
                          codeBackground: _toneColor(colors, adapter.codeTone),
                          blockBackground: _toneColor(
                            colors,
                            adapter.quoteTone,
                          ),
                          borderColor: colors.line,
                          renderStyle: adapter.markdownStyle,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

List<String> _uniqueProcessOperationKeys(
  List<AgentConversationMessage> operations,
) {
  final bases = operations
      .map(
        (message) => message.id.trim().isNotEmpty
            ? message.id.trim()
            : 'projected-${message.stableIdentity.trim().isNotEmpty ? message.stableIdentity.trim() : _stableTimelineIdentity('${message.createdAt}|${message.role}|${message.cardType}')}',
      )
      .toList(growable: false);
  final totals = <String, int>{};
  for (final base in bases) {
    totals.update(base, (value) => value + 1, ifAbsent: () => 1);
  }
  return List<String>.generate(bases.length, (index) {
    final base = bases[index];
    if (totals[base] == 1) {
      return base;
    }
    final message = operations[index];
    final immutableIdentity = message.stableIdentity.trim().isNotEmpty
        ? message.stableIdentity.trim()
        : '${message.createdAt}|${message.role}|${message.cardType}|$index';
    return '$base-${_stableTimelineIdentity(immutableIdentity)}';
  }, growable: false);
}

String _localizedHiddenProcessDetails(
  AgentConversationMessageKind kind,
  LicoStrings strings,
) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => strings.invocationDetailsHidden,
    AgentConversationMessageKind.toolResult => strings.toolResultRecorded,
    AgentConversationMessageKind.reasoning => strings.reasoningDetailsRedacted,
    AgentConversationMessageKind.metadata => strings.nativeMetadataHidden,
    AgentConversationMessageKind.error => strings.nativeAgentErrorReported,
    _ => strings.nativeEventDetailsHidden,
  };
}

bool _isDefaultProcessTitle(AgentConversationMessageKind kind, String value) {
  final normalized = value.trim().toLowerCase();
  return switch (kind) {
    AgentConversationMessageKind.toolCall => normalized == 'tool call',
    AgentConversationMessageKind.toolResult => normalized == 'tool result',
    AgentConversationMessageKind.reasoning => normalized == 'reasoning',
    AgentConversationMessageKind.metadata => normalized == 'metadata',
    AgentConversationMessageKind.error => normalized == 'error',
    _ => normalized == 'native event',
  };
}

bool _isDefaultProcessSubtitle(String value) {
  return const {
    'native agent activity',
    'native agent result',
    'reasoning summary',
    'sensitive details hidden',
    'native agent error',
    'native agent event',
  }.contains(value.trim().toLowerCase());
}

const int _maxRenderedProcessOperations = 128;
const int _maxTraversedProcessNodes = 4096;

({
  List<AgentConversationMessage> events,
  bool renderTruncated,
  int totalOperations,
  bool countTruncated,
  int issues,
  DateTime? startedAt,
  DateTime? endedAt,
})
_flattenProcessEvents(Iterable<AgentConversationMessage> events) {
  final flattened = <AgentConversationMessage>[];
  final pending = events.toList(growable: false).reversed.toList();
  final visited = <AgentConversationMessage>{};
  var totalOperations = 0;
  var issues = 0;
  var traversed = 0;
  var sourceTreeTruncated = false;
  DateTime? startedAt;
  DateTime? endedAt;
  while (pending.isNotEmpty && traversed < _maxTraversedProcessNodes) {
    final event = pending.removeLast();
    if (!visited.add(event)) {
      continue;
    }
    traversed += 1;
    if (event.childMessagesTruncated) {
      sourceTreeTruncated = true;
    }
    if (event.isStructuredEvent) {
      totalOperations += 1;
      if (event.kind == AgentConversationMessageKind.error) {
        issues += 1;
      }
      final timestamp = DateTime.tryParse(event.createdAt);
      if (timestamp != null) {
        if (startedAt == null || timestamp.isBefore(startedAt)) {
          startedAt = timestamp;
        }
        if (endedAt == null || timestamp.isAfter(endedAt)) {
          endedAt = timestamp;
        }
      }
      if (flattened.length < _maxRenderedProcessOperations) {
        flattened.add(event);
      }
    }
    for (final child in event.childMessages.reversed) {
      pending.add(child);
    }
  }
  return (
    events: List<AgentConversationMessage>.unmodifiable(flattened),
    renderTruncated:
        totalOperations > flattened.length ||
        pending.isNotEmpty ||
        sourceTreeTruncated,
    totalOperations: totalOperations,
    countTruncated: pending.isNotEmpty || sourceTreeTruncated,
    issues: issues,
    startedAt: startedAt,
    endedAt: endedAt,
  );
}

String _processTitle(DateTime? start, DateTime? end, LicoStrings strings) {
  if (start == null || end == null || end.isBefore(start)) {
    return strings.agentProcess;
  }
  final elapsedMilliseconds = end.difference(start).inMilliseconds;
  if (elapsedMilliseconds <= 0) {
    return strings.workedBriefly;
  }
  final seconds = (elapsedMilliseconds + 999) ~/ 1000;
  if (seconds < 60) {
    return strings.workedForSeconds(seconds);
  }
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  return strings.workedForMinutes(minutes, remainingSeconds);
}

String _processSummary(
  int totalOperations,
  int issues,
  bool truncated,
  LicoStrings strings,
) {
  final steps = strings.processSteps(totalOperations, truncated: truncated);
  return issues == 0 ? steps : '$steps · ${strings.processIssues(issues)}';
}

({String title, String subtitle, IconData icon, Color accent})
_eventPresentation(
  AgentConversationMessageKind kind,
  LicoThemeColors colors,
  LicoStrings strings,
) {
  return switch (kind) {
    AgentConversationMessageKind.toolCall => (
      title: strings.toolCall,
      subtitle: strings.nativeAgentActivity,
      icon: Icons.terminal_rounded,
      accent: colors.info,
    ),
    AgentConversationMessageKind.toolResult => (
      title: strings.toolResult,
      subtitle: strings.nativeAgentResult,
      icon: Icons.check_circle_outline_rounded,
      accent: colors.success,
    ),
    AgentConversationMessageKind.reasoning => (
      title: strings.reasoning,
      subtitle: strings.sensitiveDetailsHidden,
      icon: Icons.psychology_alt_outlined,
      accent: colors.textMuted,
    ),
    AgentConversationMessageKind.metadata => (
      title: strings.metadata,
      subtitle: strings.sensitiveDetailsHidden,
      icon: Icons.info_outline_rounded,
      accent: colors.textMuted,
    ),
    AgentConversationMessageKind.error => (
      title: strings.processError,
      subtitle: strings.nativeAgentError,
      icon: Icons.error_outline_rounded,
      accent: colors.error,
    ),
    _ => (
      title: strings.nativeEvent,
      subtitle: strings.nativeAgentEvent,
      icon: Icons.bolt_outlined,
      accent: colors.textMuted,
    ),
  };
}
