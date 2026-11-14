import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/conversation_execution_entry.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';

import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer_capsules.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_message_view.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_controls.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_pane_presentation.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_parity_disclosure.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/frontend/shared/messaging/conversation_motion_surface.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_virtual_machine_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/lico_plan_document_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/panel_frame.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_header_bar.dart';

/// Composes an already projected conversation view. Controller listening and
/// domain-to-presentation adaptation belong exclusively to the workspace.
class AgentConversationActivePane extends StatefulWidget {
  const AgentConversationActivePane({
    super.key,
    required this.state,
    required this.actions,
    required this.header,
    this.framed = true,
    this.messageScrollController,
    this.onComposerExtentChanged,
  });

  final AgentConversationPaneState state;
  final AgentConversationPaneActions actions;
  final Widget header;
  final bool framed;
  final ScrollController? messageScrollController;
  final ValueChanged<double>? onComposerExtentChanged;

  @override
  State<AgentConversationActivePane> createState() =>
      _AgentConversationActivePaneState();
}

class _AgentConversationActivePaneState
    extends State<AgentConversationActivePane> {
  AgentConversationPaneState get state => widget.state;
  AgentConversationPaneActions get actions => widget.actions;
  Widget get header => widget.header;
  bool get framed => widget.framed;
  ScrollController? get messageScrollController =>
      widget.messageScrollController;

  Object _motionKey = Object();
  bool _motionVisible = false;
  bool _motionAssembled = false;
  bool _pendingDraftRollover = false;

  final GlobalKey _composerDockKey = GlobalKey();
  double? _composerDockExtent;
  bool _composerMeasurePending = false;

  void _measureComposerDock() {
    if (_composerMeasurePending) return;
    _composerMeasurePending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _composerMeasurePending = false;
      if (!mounted) return;
      final box = _composerDockKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final extent = box.size.height;
      if (_composerDockExtent == extent) return;
      setState(() => _composerDockExtent = extent);
      widget.onComposerExtentChanged?.call(extent);
    });
  }

  bool _empty(AgentConversationPaneState value) =>
      !value.loading &&
      !value.messagePageLoading &&
      !_hasConversationContent(value.session?.messages ?? const []) &&
      !_hasConversationContent(value.liveMessages);

  bool _hasConversationContent(List<AgentConversationMessage> messages) =>
      messages.any(
        (message) =>
            message.cardType != 'membership-changed' &&
            message.cardType != 'availability',
      );

  @override
  void initState() {
    super.initState();
    _motionVisible = _empty(state);
  }

  @override
  void didUpdateWidget(AgentConversationActivePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.state;
    final sameTarget = previous.target.target == state.target.target;
    final sameConversation =
        sameTarget &&
        previous.session?.id == state.session?.id &&
        previous.session?.nativeSessionId == state.session?.nativeSessionId;
    final draftRollover =
        _pendingDraftRollover &&
        sameTarget &&
        previous.session == null &&
        state.liveMessages.any(
          (message) => message.kind == AgentConversationMessageKind.user,
        );
    if (draftRollover) {
      // A real composer submit armed this one draft-to-session handover.
      _pendingDraftRollover = state.session == null;
    } else if (!sameConversation) {
      _motionKey = Object();
      _motionVisible = _empty(state);
      _motionAssembled = false;
      _pendingDraftRollover = false;
    } else if (!_motionAssembled) {
      // Loading an existing history is never a first-send animation.
      _motionVisible = _empty(state);
    }
    if (_motionAssembled &&
        !state.turnActive &&
        (previous.turnActive || state.sendGateReasonCode.isNotEmpty) &&
        !state.liveMessages.any(
          (message) => message.kind == AgentConversationMessageKind.assistant,
        )) {
      _motionVisible = false;
      _pendingDraftRollover = false;
    }
  }

  Widget _motionScene(Widget child) => ConversationMotionScene(
    conversationKey: _motionKey,
    visible: _motionVisible,
    assembled: _motionAssembled,
    onSendInitiated: () {
      if (!_motionVisible || _motionAssembled) return;
      setState(() {
        _motionAssembled = true;
        _pendingDraftRollover =
            state.session == null && state.preparingNewConversation;
      });
    },
    onAssembled: () {
      if (mounted && _motionVisible) {
        setState(() {
          _motionVisible = false;
          _pendingDraftRollover = false;
        });
      }
    },
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final mobileClient = isMobileClientPlatform(context);
    final strings = LicoStrings.of(context);
    final strategy = LayoutAgentsStrategyScope.maybeOf(context);
    final unavailableCopy = conversationSendAvailabilityCopy(
      strings: strings,
      reasonCode: state.sendGateReasonCode,
    );
    final messagingFlow =
        strategy.messageStyle == AgentsMessageStyle.participantFlow;
    final composer = RuntimeMessageComposer(
      // Keyed per conversation scope: a switch starts a fresh composer state
      // seeded from that conversation's stored draft instead of relying on
      // didUpdateWidget restores that can race the debounced draft echo.
      key: ValueKey<String>(
        'composer-${state.target.target}-'
        '${state.session?.id ?? (state.preparingNewConversation ? 'draft' : 'none')}',
      ),
      targetLabel: state.conversationLabel.trim().isNotEmpty
          ? state.conversationLabel.trim()
          : agentConversationTargetDisplayName(state.target),
      initialDraft: state.composerDraft,
      hasAttachments: state.hasAttachments,
      busy: state.composerBusy,
      activityVisible: state.turnActive || state.loading || state.composerBusy,
      enabled: state.composerEnabled && state.inputEnabled,
      cancelEnabled: state.cancelEnabled,
      modelOptions: state.modelOptions,
      selectedModel: state.selectedModel,
      reasoningEffortOptions: state.reasoningEffortOptions,
      selectedReasoningEffort: state.selectedReasoningEffort,
      onModelChanged: actions.onModelChanged,
      onReasoningEffortChanged: actions.onReasoningEffortChanged,
      onDraftChanged: actions.onDraftChanged,
      onSend: actions.onSend,
      onSlashNewConversation: actions.onNewConversation,
      onCancel: actions.onCancel,
      defaultModel: state.defaultModel,
      defaultReasoningEffort: state.defaultReasoningEffort,
      showRuntimeSettings:
          strategy.composerStyle == AgentsComposerStyle.withRuntimeBar,
      showWorkingDirectory: state.showWorkingDirectory,
      workingDirectory: state.workingDirectory,
      workingDirectorySelectable: state.workingDirectorySelectable,
      onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
      floatingMatteCapsule: !mobileClient && messagingFlow,
      onAttach: actions.onAttach,
      onPasteImage: actions.onPasteImage,
      mentionTargets: state.participantTargets
          .where(
            (target) => state.composerMentionLabels.containsKey(target.target),
          )
          .toList(growable: false),
      mentionLabels: state.composerMentionLabels,
      leading: state.composerLeading,
      fieldTrailing: state.composerFieldTrailing,
    );
    final sendUnavailable = state.composerEnabled
        ? null
        : state.sendGateResolving
        ? const _ConversationSendResolvingRow()
        : _ConversationSendUnavailableRow(
            copy: unavailableCopy,
            onUnblock: unavailableCopy.unblockAction == null
                ? null
                : actions.onUnblockSend,
          );
    final sendFailure =
        state.composerEnabled &&
            !state.turnActive &&
            state.sendGateReasonCode.trim().isNotEmpty
        ? _ConversationSendFailureRow(
            message: strings.conversationSendFailed(
              unavailableCopy.reasonLabel,
            ),
            actionLabel:
                unavailableCopy.unblockAction ==
                    ConversationSendUnblockAction.authorizeRuntime
                ? (state.sendAuthorizeActive
                      ? strings.conversationAuthorizingRuntimeAction
                      : unavailableCopy.unblockLabel)
                : null,
            onAction:
                unavailableCopy.unblockAction ==
                        ConversationSendUnblockAction.authorizeRuntime &&
                    !state.sendAuthorizeActive
                ? actions.onUnblockSend
                : null,
          )
        : null;
    final permissionRetry =
        state.permissionRetryTool.trim().isNotEmpty && !state.turnActive
        ? _ConversationPermissionRetryRow(
            tool: state.permissionRetryTool,
            onAllow: actions.onPermissionRetry,
            onAllowAndRemember: actions.onPermissionRetryRemember,
            onDeny: actions.onPermissionDeny,
          )
        : null;
    final licoProfileCapsule = state.showLicoProfileCapsule
        ? ComposerLicoProfileCapsule(
            selectedProfile: state.selectedLicoProfile,
            onChanged: actions.onLicoProfileChanged ?? (_) {},
          )
        : null;
    final showComposerCapsuleRow =
        (messagingFlow &&
            ((state.showWorkingDirectory &&
                    state.workingDirectory.trim().isNotEmpty) ||
                state.modelOptions.isNotEmpty ||
                state.reasoningEffortOptions.isNotEmpty ||
                licoProfileCapsule != null)) ||
        state.composerFlywheel != null;
    // Bottom edge of the header overlay in transcript coordinates: the
    // flat bar's extent, or the capsule's bottom (inset + pad + avatar).
    final headerFadeEdge = messagingConversationHeaderUsesBar(context)
        ? messagingConversationHeaderExtentOf(context)
        : MessagingDesktopMetrics.conversationHeaderOverlayExtent -
              MessagingDesktopMetrics.conversationHeaderCapsuleInsetV;
    // The transcript's first row starts where the fade is fully opaque —
    // at rest no content sits inside the transparent band.
    final headerOverlayInset = !mobileClient && messagingFlow
        ? headerFadeEdge + ConversationTranscriptHeaderFade.fadeExtent
        : 0.0;
    final composerOverlayInset = !mobileClient && messagingFlow
        ? _composerDockExtent ??
              (MessagingDesktopMetrics.conversationComposerOverlayExtent +
                  (showComposerCapsuleRow
                      ? MessagingDesktopMetrics
                            .conversationComposerCapsuleRowExtent
                      : 0))
        : 0.0;
    // An untouched conversation lifts the composer dock to the middle of the
    // pane, under the greeting, instead of pinning it to the bottom edge.
    final transcriptEmpty =
        _empty(state) &&
        (state.session?.messages.isEmpty ?? true) &&
        state.liveMessages.isEmpty;
    final messageSurface = transcriptEmpty
        ? (messagingFlow
              ? const SizedBox.expand()
              : const _ConversationEmptyGreeting())
        : AgentConversationMessageList(
            scrollController: messageScrollController,
            loading: state.loading,
            messagePageLoading: state.messagePageLoading,
            hasEarlierMessages: state.hasEarlierMessages,
            messagePageError: state.messagePageError,
            onLoadEarlier: actions.onLoadEarlierMessages,
            session: state.session,
            target: state.target,
            turnActive: state.turnActive,
            liveMessages: state.liveMessages,
            messageStyle: strategy.messageStyle,
            participantTargets: state.participantTargets,
            participantConversationIds: state.participantConversationIds,
            participantRuntimeProfiles: state.participantRuntimeProfiles,
            assistantActive: state.assistantActive,
            topOverlayInset: headerOverlayInset,
            bottomOverlayInset: composerOverlayInset,
            onCopyText: actions.onCopyText,
            onRetryMessage: actions.onRetryMessage,
            onDeleteMessage: actions.onDeleteMessage,
          );
    final messages = RepaintBoundary(
      key: const Key('conversation-streaming-repaint-boundary'),
      child: ConversationMotionContent(child: messageSurface),
    );
    final showPlanDocumentPanel =
        !mobileClient &&
        messagingFlow &&
        state.selectedLicoProfile == 'plan' &&
        state.planDocumentPath.trim().isNotEmpty;
    final messagingHeader = header;
    if (mobileClient) {
      // Every text in the conversation pane is selectable for copy; the
      // mobile path hosts the same single pane-level SelectionArea as the
      // desktop return below.
      return _motionScene(
        ConversationExecutionScope(
          onOpen: actions.onOpenExecution,
          child: SelectionArea(
            child: Column(
              children: [
                // Console mobile surfaces the parity and VM chips above the
                // transcript; messaging keeps them inside the details sheet.
                if (!messagingFlow)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ConversationParityDisclosurePanel(
                            target: state.target,
                            compact: true,
                          ),
                          if (state.target.hasValidVirtualMachineConnection)
                            ConversationVirtualMachineDestinationChip(
                              destination:
                                  state.target.virtualMachineDestination,
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(child: messages),
                ?sendUnavailable,
                ?sendFailure,
                ?permissionRetry,
                if (showComposerCapsuleRow)
                  ComposerCapsuleRow(
                    modelOptions: state.modelOptions,
                    selectedModel: state.selectedModel,
                    defaultModel: state.defaultModel,
                    modelSelectionEnabled: state.composerEnabled,
                    onModelChanged: actions.onModelChanged,
                    reasoningEffortOptions: state.reasoningEffortOptions,
                    selectedReasoningEffort: state.selectedReasoningEffort,
                    defaultReasoningEffort: state.defaultReasoningEffort,
                    onReasoningEffortChanged: actions.onReasoningEffortChanged,
                    licoProfileCapsule: licoProfileCapsule,
                    assistantCapsule: state.composerAssistantCapsule,
                    flywheel: state.composerFlywheel,
                  ),
                MobileComposerSurface(child: composer),
              ],
            ),
          ),
        ),
      );
    }
    // Messaging: header and composer overlay the full-height transcript.
    // Execution feedback belongs to the composer border in every layout.
    if (messagingFlow) _measureComposerDock();
    final bottomDock = NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _measureComposerDock();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        key: _composerDockKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?sendUnavailable,
            ?sendFailure,
            ?permissionRetry,
            if (showComposerCapsuleRow)
              ComposerCapsuleRow(
                workingDirectory: state.showWorkingDirectory
                    ? state.workingDirectory
                    : null,
                workingDirectorySelectable: state.workingDirectorySelectable,
                onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
                modelOptions: state.modelOptions,
                selectedModel: state.selectedModel,
                defaultModel: state.defaultModel,
                modelSelectionEnabled: state.composerEnabled,
                onModelChanged: actions.onModelChanged,
                reasoningEffortOptions: state.reasoningEffortOptions,
                selectedReasoningEffort: state.selectedReasoningEffort,
                defaultReasoningEffort: state.defaultReasoningEffort,
                onReasoningEffortChanged: actions.onReasoningEffortChanged,
                licoProfileCapsule: licoProfileCapsule,
                assistantCapsule: state.composerAssistantCapsule,
                flywheel: state.composerFlywheel,
              ),
            composer,
          ],
        ),
      ),
    );
    final content = Column(
      children: [
        if (messagingFlow)
          Expanded(
            child: showPlanDocumentPanel
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            ConversationTranscriptHeaderFade(
                              headerBottom: headerFadeEdge,
                              child: messages,
                            ),
                            Align(
                              alignment: Alignment.topCenter,
                              child: messagingHeader,
                            ),
                            Align(
                              alignment: Alignment.bottomCenter,
                              child: bottomDock,
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 300,
                        child: LicoPlanDocumentPanel(
                          planPath: state.planDocumentPath,
                          loader: state.planDocumentLoader,
                          refreshToken:
                              state.liveMessages.length +
                              (state.turnActive ? 1 : 0),
                        ),
                      ),
                    ],
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      ConversationTranscriptHeaderFade(
                        headerBottom: headerFadeEdge,
                        child: messages,
                      ),
                      Align(
                        alignment: Alignment.topCenter,
                        child: messagingHeader,
                      ),
                      if (transcriptEmpty)
                        Column(
                          children: [
                            const Spacer(flex: 5),
                            const _ConversationEmptyGreeting(expanded: false),
                            const SizedBox(height: 28),
                            bottomDock,
                            const Spacer(flex: 6),
                          ],
                        )
                      else
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: bottomDock,
                        ),
                    ],
                  ),
          )
        else ...[
          header,
          const Divider(height: 2),
          Expanded(child: messages),
          const Divider(height: 1),
          ?sendUnavailable,
          ?sendFailure,
          ?permissionRetry,
          if (showComposerCapsuleRow)
            ComposerCapsuleRow(
              workingDirectory: state.showWorkingDirectory
                  ? state.workingDirectory
                  : null,
              workingDirectorySelectable: state.workingDirectorySelectable,
              onChooseWorkingDirectory: actions.onChooseWorkingDirectory,
              modelOptions: state.modelOptions,
              selectedModel: state.selectedModel,
              defaultModel: state.defaultModel,
              modelSelectionEnabled: state.composerEnabled,
              onModelChanged: actions.onModelChanged,
              reasoningEffortOptions: state.reasoningEffortOptions,
              selectedReasoningEffort: state.selectedReasoningEffort,
              defaultReasoningEffort: state.defaultReasoningEffort,
              onReasoningEffortChanged: actions.onReasoningEffortChanged,
              licoProfileCapsule: licoProfileCapsule,
              assistantCapsule: state.composerAssistantCapsule,
              flywheel: state.composerFlywheel,
            ),
          composer,
        ],
      ],
    );
    // Messaging capsules float on the glass canvas — PanelFrame's surface
    // band + border would reintroduce a full-width header partition.
    final useFrame = framed && !messagingFlow;
    final pane = useFrame ? PanelFrame(child: content) : content;
    // Every text in the conversation pane is selectable for copy.
    return _motionScene(
      ConversationExecutionScope(
        onOpen: actions.onOpenExecution,
        child: SelectionArea(child: pane),
      ),
    );
  }
}

/// Fades the transcript in below the overlay conversation header: fully
/// transparent at the header's bottom edge, opaque [fadeExtent] px beneath
/// it, so scrolled content never reads through the translucent header in
/// any profile (bar or capsule).
final class ConversationTranscriptHeaderFade extends StatelessWidget {
  const ConversationTranscriptHeaderFade({
    super.key,
    required this.headerBottom,
    required this.child,
  });

  /// Bottom edge of the header overlay in transcript coordinates.
  final double headerBottom;
  final Widget child;

  /// Distance over which the transcript fades from clear to opaque.
  static const double fadeExtent = 24;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final h = rect.height <= 0 ? 1.0 : rect.height;
        final edge = (headerBottom / h).clamp(0.0, 1.0);
        final full = ((headerBottom + fadeExtent) / h).clamp(0.0, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [
            Color(0x00000000),
            Color(0x00000000),
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
          ],
          stops: [0, edge, full, 1],
        ).createShader(rect);
      },
      child: child,
    );
  }
}

class _ConversationSendFailureRow extends StatelessWidget {
  const _ConversationSendFailureRow({
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      key: const Key('conversation-send-failed'),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 14, color: colors.error),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              key: const Key('conversation-send-failed-reason'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              key: const Key('conversation-send-failed-action'),
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

class _ConversationPermissionRetryRow extends StatelessWidget {
  const _ConversationPermissionRetryRow({
    required this.tool,
    this.onAllow,
    this.onAllowAndRemember,
    this.onDeny,
  });

  /// Matches the site's `.approval-card` box metrics.
  static const double cardRadius = 16;
  static const double lockTileRadius = 10;
  static const double actionRadius = 10;

  final String tool;
  final VoidCallback? onAllow;
  final VoidCallback? onAllowAndRemember;
  final VoidCallback? onDeny;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    // The permission card carries the gold family: the waffle-textured accent
    // wash in light presets, the gold brand wash with a brand glow in dark
    // presets — the same surface the site's approval card uses.
    final cardFill = colors.isDark ? colors.brandSurface : colors.accentSurface;
    final cardBorder = colors.isDark ? colors.brandBorder : colors.accentBorder;
    final cardShape = ContinuousRoundedBorder(
      borderRadius: BorderRadius.circular(cardRadius),
    );
    final actionTextStyle = const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    final actionPadding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 7,
    );
    final actionShape = ContinuousRoundedBorder(
      borderRadius: BorderRadius.circular(actionRadius),
    );
    return Padding(
      key: const Key('conversation-permission-retry'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ClipPath.shape(
            shape: cardShape,
            child: Container(
              decoration: continuousHairlineDecoration(
                color: cardFill,
                borderRadius: BorderRadius.circular(cardRadius),
                stroke: cardBorder,
                shadows: colors.isDark
                    ? [BoxShadow(color: colors.brandGlow, blurRadius: 24)]
                    : null,
              ),
              child: Stack(
                children: [
                  if (!colors.isDark)
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: CustomPaint(painter: _ApprovalWafflePainter()),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          alignment: Alignment.center,
                          decoration: ShapeDecoration(
                            color: colors.isDark
                                ? colors.text.withValues(alpha: 0.06)
                                : colors.surface,
                            shape: ContinuousRoundedBorder(
                              borderRadius: BorderRadius.circular(
                                lockTileRadius,
                              ),
                              side: BorderSide(
                                color: colors.isDark
                                    ? colors.brandBorder
                                    : colors.line,
                              ),
                            ),
                          ),
                          child: Icon(
                            Icons.lock_outline_rounded,
                            size: 17,
                            color: colors.isDark
                                ? colors.primaryStrong
                                : colors.accent,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            strings.conversationPermissionDenied(tool),
                            key: const Key(
                              'conversation-permission-retry-reason',
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Flexible(
                          child: Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                key: const Key(
                                  'conversation-permission-retry-deny',
                                ),
                                onPressed: onDeny,
                                style: TextButton.styleFrom(
                                  foregroundColor: colors.error,
                                  backgroundColor: colors.isDark
                                      ? (colors.isDark
                                            ? LicoPaneGlass.contentInnerCardFill
                                            : colors.surfaceRaised)
                                      : colors.surface,
                                  shape: actionShape.copyWith(
                                    side: BorderSide(color: colors.line),
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: actionPadding,
                                  textStyle: actionTextStyle,
                                ),
                                child: Text(
                                  strings.conversationPermissionDenyAction,
                                ),
                              ),
                              TextButton(
                                key: const Key(
                                  'conversation-permission-retry-remember',
                                ),
                                onPressed: onAllowAndRemember,
                                style: TextButton.styleFrom(
                                  foregroundColor: colors.textSecondary,
                                  backgroundColor: colors.isDark
                                      ? (colors.isDark
                                            ? LicoPaneGlass.contentInnerCardFill
                                            : colors.surfaceRaised)
                                      : colors.surface,
                                  shape: actionShape.copyWith(
                                    side: BorderSide(color: colors.line),
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: actionPadding,
                                  textStyle: actionTextStyle,
                                ),
                                child: Text(
                                  strings
                                      .conversationPermissionAllowAndRememberAction,
                                ),
                              ),
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    actionRadius,
                                  ),
                                  boxShadow: colors.isDark
                                      ? [
                                          BoxShadow(
                                            color: colors.brandGlow,
                                            blurRadius: 14,
                                          ),
                                        ]
                                      : null,
                                ),
                                child: TextButton(
                                  key: const Key(
                                    'conversation-permission-retry-action',
                                  ),
                                  onPressed: onAllow,
                                  style: TextButton.styleFrom(
                                    foregroundColor: colors.textOnSelection,
                                    backgroundColor: colors.selectionInk,
                                    shape: actionShape,
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    padding: actionPadding,
                                    textStyle: actionTextStyle,
                                  ),
                                  child: Text(
                                    strings.conversationPermissionAllowAction,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The site's `.approval-card` waffle: two 45° crosshatch passes of a 1 px
/// warm-tan groove at 9 px pitch, painted only under the light accent wash.
final class _ApprovalWafflePainter extends CustomPainter {
  const _ApprovalWafflePainter();

  static const _groove = Color.fromRGBO(176, 122, 67, 0.18);
  static const _pitch = 9.0 * 1.4142135623730951;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = _groove
      ..strokeWidth = 1;
    for (var x = 0.0; x <= size.width + size.height; x += _pitch) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x - size.height, size.height),
        paint,
      );
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ApprovalWafflePainter oldDelegate) => false;
}

class _ConversationSendUnavailableRow extends StatelessWidget {
  const _ConversationSendUnavailableRow({required this.copy, this.onUnblock});

  final ConversationSendAvailabilityCopy copy;
  final VoidCallback? onUnblock;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('conversation-send-unavailable'),
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: colors.warning),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              copy.reasonLabel,
              key: const Key('conversation-send-unavailable-reason'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
          if (copy.unblockAction != null && onUnblock != null)
            TextButton(
              key: const Key('conversation-send-unavailable-action'),
              onPressed: onUnblock,
              style: TextButton.styleFrom(
                foregroundColor: colors.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(copy.unblockLabel ?? strings.refreshAgents),
            ),
        ],
      ),
    );
  }
}

/// Rendered while a scan or the selection-time executable binding still
/// resolves a runtime-gate code: the row is a loading affordance, never a
/// verdict — a listed agent was already discovered, so "not detected" copy
/// can only be a transient scan state.
class _ConversationSendResolvingRow extends StatelessWidget {
  const _ConversationSendResolvingRow();

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      key: const Key('conversation-send-resolving'),
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              strings.conversationSendResolving,
              key: const Key('conversation-send-resolving-label'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The empty conversation moment: the bundled Lico mascot waves in, with a
/// quiet greeting under it. This is the mascot's home in the client — the
/// same character that greets from the website hero.
class _ConversationEmptyGreeting extends StatelessWidget {
  const _ConversationEmptyGreeting({this.expanded = true});

  /// Whether the greeting fills its parent; the centered composer variant
  /// shrinks to its content so the dock can sit directly beneath.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    if (!expanded) {
      return _greeting(colors, strings);
    }
    return SizedBox.expand(child: Center(child: _greeting(colors, strings)));
  }

  Widget _greeting(LicoThemeColors colors, LicoStrings strings) {
    return Column(
      key: const Key('conversation-empty-content'),
      mainAxisSize: MainAxisSize.min,
      children: [
        MascotImage.expression(
          'hi',
          key: const Key('conversation-empty-mascot'),
          size: 96,
          semanticLabel: MascotCatalog.expressionName(
            'hi',
            chinese: strings.isChinese,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          strings.conversationEmptyGreeting,
          key: const Key('conversation-empty-greeting'),
          style: TextStyle(
            color: colors.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}
