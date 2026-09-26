import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/project_collaboration_root.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/layout_value_builder.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/environment/workspace_home_directory_scope.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_composer.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/assistant_configuration_dialog.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/projection.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/canonical_group_conversation_pane/strategy.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_pairing_channels.dart';
import 'package:licoup/src/frontend/features/models/ui/models_panel.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_builder.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

typedef ExternalUriOpener = Future<void> Function(Uri uri);

/// Concrete renderer factory assembled only at the composition boundary.
///
/// The shell chrome consumes the runtime-backed presentation sources: the
/// application-scope [PresentationRuntime] owns source observation and
/// authority revocation, so the renderer never reads the raw projection
/// owners directly and never re-serves a withdrawn value.
final class BindingShellRenderer implements ShellRendererPort {
  BindingShellRenderer({
    required BuiltInLayoutComposition layout,
    required IntentSink<ShellIntent> shellIntents,
    required PresentationRuntime runtime,
    required PresentationSource<ChromeProjection> chromeSource,
    required PresentationSource<StatusProjection> statusSource,
    required PresentationSource<LocaleProjection> localeSource,
    required AgentsBinding agents,
    required ConversationBinding conversation,
    required MonitoringBinding monitoring,
    required SkillHubBinding skillHub,
    required PluginManagementBinding pluginManagement,
    required MobileRelayBinding mobileRelay,
    required ModelsBinding models,
    required SettingsBinding settings,
    required AgentHubBinding agentHub,
    required SearchBinding search,
    required TargetsBinding targets,
    required ExternalUriOpener openExternalUri,
    required String workspaceHomeDirectory,
  }) : _layout = layout,
       _shellIntents = shellIntents,
       _runtime = runtime,
       _chromeSource = chromeSource,
       _agents = agents,
       _conversation = conversation,
       _monitoring = monitoring,
       _skillHub = skillHub,
       _pluginManagement = pluginManagement,
       _mobileRelay = mobileRelay,
       _models = models,
       _settings = settings,
       _agentHub = agentHub,
       _targets = targets,
       _openExternalUri = openExternalUri,
       _workspaceHomeDirectory = workspaceHomeDirectory,
       _chrome = _BindingLayoutChrome(
         runtime: runtime,
         status: statusSource,
         locale: localeSource,
         mobileRelay: mobileRelay,
         search: search,
       );

  final BuiltInLayoutComposition _layout;
  final IntentSink<ShellIntent> _shellIntents;
  final PresentationRuntime _runtime;
  final PresentationSource<ChromeProjection> _chromeSource;
  final AgentsBinding _agents;
  final ConversationBinding _conversation;
  final MonitoringBinding _monitoring;
  final SkillHubBinding _skillHub;
  final PluginManagementBinding _pluginManagement;
  final MobileRelayBinding _mobileRelay;
  final ModelsBinding _models;
  final SettingsBinding _settings;
  final AgentHubBinding _agentHub;
  final TargetsBinding _targets;
  final ExternalUriOpener _openExternalUri;
  final String _workspaceHomeDirectory;
  final _BindingLayoutChrome _chrome;
  bool _disposed = false;

  @override
  LayoutRegistry get layoutRegistry => _layout.registry;

  @override
  LayoutStatePort get layoutStateStore => _layout.stateStore;

  @override
  LayoutChromePort get chrome => _chrome;

  @override
  LayoutChromeFeatures createChromeFeatures(
    ValueNotifier<bool> auxChromePanelOpen,
  ) => _BindingChromeFeatures(
    runtime: _runtime,
    chromeSource: _chromeSource,
    agents: _agents,
    conversation: _conversation,
    auxChromePanelOpen: auxChromePanelOpen,
  );

  @override
  GlobalKey createAgentsHomeKey() => GlobalKey<MobileAgentsHomeState>();

  @override
  Widget buildDestination(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  }) => switch (destination) {
    ClientSection.agents => WorkspaceHomeDirectoryScope(
      path: _workspaceHomeDirectory,
      child: AgentsCanvas(
        agents: _agents,
        conversation: _conversation,
        relay: _mobileRelay,
        monitoring: _monitoring,
        targets: _targets,
        onSelectDestination: (destination) =>
            _shellIntents.send(SelectShellDestination(destination)),
        agentsHomeKey: agentsHomeKey as GlobalKey<MobileAgentsHomeState>,
      ),
    ),
    ClientSection.monitoring => AgentUsagePanel(binding: _monitoring),
    ClientSection.skillHub => SkillHubPanel(binding: _skillHub),
    ClientSection.pluginManagement => AdapterPluginPanel(
      binding: _pluginManagement,
    ),
    ClientSection.mobileRelay => MobileRelayPanel(
      binding: _mobileRelay,
      chatChannels: MobilePairingChannels(binding: _models),
    ),
    ClientSection.models => ModelsPanel(
      binding: _models,
      pane: ModelsPanelPane.gateway,
    ),
    ClientSection.settings => SettingsPanel(
      binding: _settings,
      layoutRegistry: _layout.registry,
    ),
    ClientSection.agentHub => _FeatureDestinationHost(
      agentHub: AgentHubPanel(
        binding: _agentHub,
        plugins: _pluginManagement,
        skills: _skillHub,
        openHomepage: _openExternalUri,
        onOpenAgent: (agentId) => _shellIntents.send(OpenShellAgent(agentId)),
      ),
    ),
  };

  @override
  void resetAgentsHome(GlobalKey agentsHomeKey) {
    final state = agentsHomeKey.currentState;
    if (state is MobileAgentsHomeState) state.resetToList();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _chrome.dispose();
  }
}

/// Both feature entries use the existing retained feature host. Layouts decide
/// where that host sits; it never replaces the permanent conversation surface.
final class _FeatureDestinationHost extends StatelessWidget {
  const _FeatureDestinationHost({required this.agentHub});

  final Widget agentHub;

  @override
  Widget build(BuildContext context) {
    final state = LayoutScope.maybeOf(context)?.state;
    int selection() {
      final tab = state?.readIfDeclaredFor(
        ClientSection.agentHub,
        LayoutStateChannels.featureSection,
      );
      return tab is LayoutTabState && tab.index == 1 ? 1 : 0;
    }

    return LayoutValuesBuilder(
      state: state,
      valuesOf: (_) => [selection()],
      builder: (context) => selection() == 1
          ? KeyedSubtree(
              key: const ValueKey('project-swimlanes-feature-content'),
              child: ProjectCollaborationRoot.layerOf(context),
            )
          : agentHub,
    );
  }
}

final class _BindingChromeFeatures implements LayoutChromeFeatures {
  _BindingChromeFeatures({
    required PresentationRuntime runtime,
    required PresentationSource<ChromeProjection> chromeSource,
    required this.agents,
    required this.conversation,
    required this.auxChromePanelOpen,
  }) : notificationNotices = _ChromeNoticesListenable(
         runtime: runtime,
         source: chromeSource,
       );

  final AgentsBinding agents;
  final ConversationBinding conversation;

  @override
  final ValueListenable<LicoToastNoticesSnapshot> notificationNotices;

  @override
  final ValueNotifier<bool> auxChromePanelOpen;

  @override
  Widget buildDockComposer(BuildContext context, {bool expanded = false}) =>
      _DockConversationComposer(
        agents: agents,
        conversation: conversation,
        expanded: expanded,
      );

  @override
  void activateOperationNotice(ChromeOperationNotificationProjection notice) {
    final target = notice.completionTarget;
    if (target == null) return;
    conversation.intents.send(
      ActivateContinuityCompletionNotice(notificationId: target.notificationId),
    );
  }
}

/// Maps the runtime-backed chrome source to the toast notices snapshot.
///
/// One subscription per attached listener observes the source through the
/// application-scope runtime, so the exposure owns no persistent subscription
/// of its own and the value is seeded from the already-admitted snapshot when
/// one exists. A revoked or failing source clears the snapshot instead of
/// re-serving the withdrawn value.
final class _ChromeNoticesListenable
    implements ValueListenable<LicoToastNoticesSnapshot> {
  _ChromeNoticesListenable({required this.runtime, required this.source});

  final PresentationRuntime runtime;
  final PresentationSource<ChromeProjection> source;
  final Map<VoidCallback, _ChromeNoticesSubscription> _subscriptions =
      <VoidCallback, _ChromeNoticesSubscription>{};
  LicoToastNoticesSnapshot _value = const LicoToastNoticesSnapshot();
  bool _seeded = false;

  @override
  LicoToastNoticesSnapshot get value {
    _seedFromRuntime();
    return _value;
  }

  @override
  void addListener(VoidCallback listener) {
    if (_subscriptions.containsKey(listener)) return;
    _seedFromRuntime();
    _subscriptions[listener] = _observe(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    final subscription = _subscriptions.remove(listener);
    if (subscription == null) return;
    unawaited(subscription.cancel());
  }

  void _seedFromRuntime() {
    if (_seeded) return;
    _seeded = true;
    final admitted = runtime.current(source.fieldGroup);
    if (admitted != null) _value = _snapshot(admitted.value);
  }

  _ChromeNoticesSubscription _observe(VoidCallback listener) {
    final observation = runtime.observe(source);
    final subscription = observation.stream.listen(
      (snapshot) {
        _value = _snapshot(snapshot.value);
        listener();
      },
      onError: (Object error, StackTrace stack) {
        // Authority withdrawal and source failure both make the withdrawn
        // notices invisible; the next admitted snapshot republishes.
        _value = const LicoToastNoticesSnapshot();
        listener();
      },
    );
    return _ChromeNoticesSubscription(observation, subscription);
  }

  static LicoToastNoticesSnapshot _snapshot(ChromeProjection projection) {
    final operationNotices = projection.operationNotifications.isNotEmpty
        ? projection.operationNotifications
        : [
            for (final notice in projection.notifications)
              ChromeOperationNotificationProjection(
                id: notice.id,
                messageChinese: notice.message,
                messageEnglish: notice.message,
                severity: notice.severity,
                reasonCode: notice.reasonCode,
              ),
          ];
    return LicoToastNoticesSnapshot(
      operationNotices: operationNotices,
      agentNotices: [
        for (final notice in projection.agentNotifications)
          LicoToastAgentNotice(
            id: notice.target.id,
            displayName: agentConversationTargetDisplayName(notice.target),
            activity: notice.activity,
          ),
      ],
      gatewayNotice: projection.gatewayNotification,
      operationRevision: projection.operationAutoRevealRevision,
      gatewayRevision: projection.gatewayAutoRevealRevision,
    );
  }
}

final class _ChromeNoticesSubscription {
  _ChromeNoticesSubscription(this._observation, this._streamSubscription);

  final ResourceObservationSubscription<ChromeProjection> _observation;
  final StreamSubscription<ResourceSnapshot<ChromeProjection>>
  _streamSubscription;

  Future<void> cancel() async {
    await _streamSubscription.cancel();
    await _observation.close();
  }
}

/// The conversation composer re-parented into the Desktop bottom bar. Sends
/// through the same conversation intents as the in-workspace composer; the
/// Desktop shell hides the workspace's internal composer while this is
/// hosted. When [expanded] is true (the left pane is collapsed), the
/// composer carries the Assistant and Adaptive Flywheel capsules in a row
/// that pops in above the field, and the canonical pane suppresses its own
/// copies through `LayoutExternalComposerScope.hostedCapsules`.
final class _DockConversationComposer extends StatefulWidget {
  const _DockConversationComposer({
    required this.agents,
    required this.conversation,
    required this.expanded,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;
  final bool expanded;

  @override
  State<_DockConversationComposer> createState() =>
      _DockConversationComposerState();
}

final class _DockConversationComposerState
    extends State<_DockConversationComposer> {
  /// Session-scoped assistant participation, mirroring the in-pane capsule's
  /// per-conversation toggle so the docked composer's sends honor it.
  final Map<String, bool> _assistantActiveByConversation = <String, bool>{};

  /// The runtime-backed plane port this dock reads.
  ///
  /// Bound from the surrounding container once and kept for the dock's life:
  /// remounting the dock reuses the same port instance, so it can neither open
  /// a second source nor revive a withdrawn plane.
  ConversationSourcePort? _boundPort;
  final List<StreamSubscription<Object?>> _planeReads =
      <StreamSubscription<Object?>>[];
  ComposerProjection? _composer;
  PersistentTurnProjection? _turns;
  ConversationAttachmentsProjection? _attachments;
  ConversationProjection? _root;
  CanonicalConversationProjection? _canonical;

  ConversationBinding get conversation => widget.conversation;
  AgentsBinding get agents => widget.agents;

  @override
  void dispose() {
    _unbindPlanes();
    super.dispose();
  }

  void _bindPlanes(ConversationSourcePort port) {
    if (identical(_boundPort, port)) return;
    _unbindPlanes();
    _boundPort = port;
    _composer = port.composer.visibleValue;
    _turns = port.persistentTurns.visibleValue;
    _attachments = port.attachments.visibleValue;
    _root = port.projection.visibleValue;
    _canonical = port.canonicalEvents.visibleValue;
    _planeReads
      ..add(
        port.composer.reads.listen(
          (read) => _applyPlane(() => _composer = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.persistentTurns.reads.listen(
          (read) => _applyPlane(() => _turns = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.attachments.reads.listen(
          (read) => _applyPlane(() => _attachments = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.projection.reads.listen(
          (read) => _applyPlane(() => _root = _visiblePlaneValue(read)),
        ),
      )
      ..add(
        port.canonicalEvents.reads.listen(
          (read) => _applyPlane(() => _canonical = _visiblePlaneValue(read)),
        ),
      );
  }

  void _unbindPlanes() {
    for (final subscription in _planeReads) {
      unawaited(subscription.cancel());
    }
    _planeReads.clear();
    _boundPort = null;
  }

  void _applyPlane(VoidCallback mutate) {
    if (!mounted) return;
    setState(mutate);
  }

  static T? _visiblePlaneValue<T>(ConversationPlaneRead<T> read) =>
      read is ConversationPlaneVisible<T> ? read.value : null;

  bool _assistantActive(ClientConversation conversation) =>
      _assistantActiveByConversation[conversation.id] ??
      conversation.assistantMembership != null;

  void _toggleAssistant(ClientConversation conversation) {
    setState(() {
      _assistantActiveByConversation[conversation.id] = !_assistantActive(
        conversation,
      );
    });
  }

  Future<void> _openAssistantConfiguration() async {
    await showAssistantConfigurationDialog(
      context,
      conversation: widget.conversation,
      agents: widget.agents,
    );
    if (!mounted) return;
    widget.conversation.intents.send(const RefreshCanonicalAssistantProfile());
  }

  @override
  Widget build(BuildContext context) {
    // The dock reads the conversation planes the runtime admitted, never the
    // producer's raw projections: a withdrawn plane stays invisible here, and
    // the agents catalog it enriches itself with comes from its own source.
    _bindPlanes(conversationSourcePortOf(context));
    final composer = _composer;
    if (composer == null) {
      return const SizedBox.shrink();
    }
    return AsyncRegion<AgentsProjection, IntentSink<AgentsIntent>>(
      source: agentsCatalogProjectionProvider,
      actions: agents.intents,
      data: (context, agentsProjection, _) => _buildComposer(
        context,
        composer: composer,
        turns: _turns,
        attachments: _attachments,
        root: _root,
        canonical: _canonical,
        agentsProjection: agentsProjection,
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context, {
    required ComposerProjection composer,
    required PersistentTurnProjection? turns,
    required ConversationAttachmentsProjection? attachments,
    required ConversationProjection? root,
    required CanonicalConversationProjection? canonical,
    required AgentsProjection agentsProjection,
  }) {
    final strings = LicoStrings.of(context);
    final memberships =
        turns?.memberships ?? const <MembershipTurnProjection>[];
    final turn = memberships.isEmpty ? null : memberships.first;
    final turnActive =
        turn?.phase == PersistentTurnPhase.running ||
        turn?.phase == PersistentTurnPhase.waiting;

    final authority = root?.authority;
    final canonicalConversation =
        authority == ConversationAuthority.canonicalConversation
        ? canonical?.conversation
        : null;

    final String targetLabel;
    final bool enabled;
    final bool busy;
    final Future<bool> Function(String) onSend;
    final Future<void> Function()? onCancel;
    final VoidCallback? onSlashNewConversation;
    final List<String> modelOptions;
    final String selectedModel;
    final String defaultModel;
    final List<String> reasoningEffortOptions;
    final String selectedReasoningEffort;
    final String defaultReasoningEffort;
    final List<TargetCandidate> mentionTargets;
    final Map<String, String> mentionLabels;

    if (canonicalConversation != null && attachments != null) {
      final group = canonicalConversation;
      mentionLabels = <String, String>{
        for (final membership in group.activeAgentMemberships)
          membership.principal.agentId: membership.principal.displayName,
      };
      mentionTargets = agentsProjection.targetDetails
          .where((target) => mentionLabels.containsKey(target.target))
          .toList(growable: false);
      targetLabel = group.title.trim().isNotEmpty
          ? group.title.trim()
          : strings.groupConversation;
      enabled =
          group.localOwnerMembership != null &&
          memberships.every((membership) => membership.inputEnabled);
      busy = canonical!.sending || turnActive;
      onSend = (content) => _sendCanonical(
        conversation: group,
        composer: composer,
        attachments: attachments,
        content: content,
      );
      final cancellable = memberships
          .where((membership) => membership.cancelEnabled)
          .toList(growable: false);
      onCancel = cancellable.length == 1
          ? () async => conversation.intents.send(
              InterruptConversationTurn(
                canonical.conversationId,
                cancellable.single.membershipId,
              ),
            )
          : null;
      onSlashNewConversation = null;
      modelOptions = const <String>[];
      selectedModel = '';
      defaultModel = '';
      reasoningEffortOptions = const <String>[];
      selectedReasoningEffort = '';
      defaultReasoningEffort = '';
    } else if (authority != null &&
        authority != ConversationAuthority.canonicalConversation) {
      TargetCandidate? selectedTarget;
      for (final target in agentsProjection.targetDetails) {
        if (target.id == agentsProjection.selectedAgentId ||
            target.target == agentsProjection.selectedAgentId) {
          selectedTarget = target;
          break;
        }
      }
      targetLabel = selectedTarget == null
          ? ''
          : agentConversationTargetDisplayName(selectedTarget);
      enabled =
          selectedTarget != null &&
          composer.inputEnabled &&
          (turn?.inputEnabled ?? true);
      busy = turnActive;
      onSend = (content) async {
        conversation.intents.send(
          PostConversationMessage(
            conversationId: composer.conversationId,
            content: content,
            addressedMembershipIds: [
              if (turn?.membershipId.trim().isNotEmpty == true)
                turn!.membershipId,
            ],
            dispatchCanonical: false,
          ),
        );
        return true;
      };
      onCancel = turn?.cancelEnabled == true
          ? () async => conversation.intents.send(
              InterruptConversationTurn(
                composer.conversationId,
                turn!.membershipId,
              ),
            )
          : null;
      onSlashNewConversation = selectedTarget == null
          ? null
          : () => conversation.intents.send(const StartConversationSession());
      modelOptions = composer.modelOptions;
      selectedModel = composer.selectedModel;
      defaultModel = composer.defaultModel;
      reasoningEffortOptions = composer.reasoningEffortOptions;
      selectedReasoningEffort = composer.selectedReasoningEffort;
      defaultReasoningEffort = composer.defaultReasoningEffort;
      mentionTargets = const <TargetCandidate>[];
      mentionLabels = const <String, String>{};
    } else {
      // The conversation identity or its attachment transport is not visible:
      // the admitted draft stays readable, but the dock neither fabricates an
      // identity nor sends through a plane the runtime has not authorized.
      targetLabel = '';
      enabled = false;
      busy = false;
      onSend = (_) async => false;
      onCancel = null;
      onSlashNewConversation = null;
      modelOptions = const <String>[];
      selectedModel = '';
      defaultModel = '';
      reasoningEffortOptions = const <String>[];
      selectedReasoningEffort = '';
      defaultReasoningEffort = '';
      mentionTargets = const <TargetCandidate>[];
      mentionLabels = const <String, String>{};
    }

    final composerWidget = RuntimeMessageComposer(
      // Same keying rule as the in-workspace composer: a conversation switch
      // starts a fresh composer state seeded from that conversation's draft.
      key: ValueKey<String>('dock-composer-${composer.conversationId}'),
      targetLabel: targetLabel,
      initialDraft: composer.draft,
      hasAttachments: attachments?.attachments.isNotEmpty ?? false,
      busy: busy,
      enabled: enabled,
      cancelEnabled: onCancel != null,
      modelOptions: modelOptions,
      selectedModel: selectedModel,
      reasoningEffortOptions: reasoningEffortOptions,
      selectedReasoningEffort: selectedReasoningEffort,
      onModelChanged: (model) =>
          conversation.intents.send(SelectConversationModel(model)),
      onReasoningEffortChanged: (effort) =>
          conversation.intents.send(SelectConversationReasoningEffort(effort)),
      onDraftChanged: (draft) => conversation.intents.send(
        UpdateConversationDraft(composer.conversationId, draft),
      ),
      onSend: onSend,
      onSlashNewConversation: onSlashNewConversation,
      onCancel: onCancel,
      defaultModel: defaultModel,
      defaultReasoningEffort: defaultReasoningEffort,
      showRuntimeSettings: false,
      // Resting (left pane open): a compact single-row capsule pinned to the
      // icon strip's height. Expanded (left collapsed): the floating capsule
      // grows upward with its lines.
      floatingMatteCapsule: widget.expanded,
      fixedHeight: widget.expanded ? null : DesktopDesktopMetrics.dockBarHeight,
      // The Desktop bottom bar positions the composer; the capsule must sit
      // flush on the bar's grid.
      outerPadding: EdgeInsets.zero,
      onPasteImage: (attachments?.acceptsImages ?? false)
          ? () async {
              conversation.intents.send(
                PasteConversationAttachment(composer.conversationId),
              );
              return true;
            }
          : null,
      mentionTargets: mentionTargets,
      mentionLabels: mentionLabels,
    );
    final group = canonicalConversation;
    // The capsule row decorates the composer with canonical plane content; an
    // invisible plane only drops the decoration, never the admitted input.
    if (!widget.expanded ||
        group == null ||
        canonical == null ||
        turns == null) {
      return composerWidget;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DockComposerCapsuleRow(
          key: ValueKey<String>('dock-composer-capsules-${group.id}'),
          conversation: group,
          canonical: canonical,
          turns: turns,
          agentsProjection: agentsProjection,
          assistantActive: _assistantActive(group),
          onToggleAssistant: () => _toggleAssistant(group),
          onEditAssistant: () => unawaited(_openAssistantConfiguration()),
          onOpenFlywheel: (revision) => unawaited(
            showAdaptiveFlywheelDialog(
              context,
              conversation: widget.conversation,
              agents: widget.agents,
              initialRevision: revision ?? '',
            ),
          ),
        ),
        const SizedBox(height: 6),
        composerWidget,
      ],
    );
  }

  Future<bool> _sendCanonical({
    required ClientConversation conversation,
    required ComposerProjection composer,
    required ConversationAttachmentsProjection attachments,
    required String content,
  }) async {
    if (attachments.attachments.isNotEmpty && !attachments.acceptsImages) {
      this.conversation.intents.send(
        SurfaceConversationFailure(
          stage: 'send',
          reasonCode: 'attachment_transport_unsupported',
          conversationId: conversation.id,
        ),
      );
      return false;
    }
    this.conversation.intents.send(
      PostConversationMessage(
        conversationId: composer.conversationId,
        content: content,
        addressedMembershipIds: [
          for (final membership in conversation.activeAgentMemberships)
            membership.id,
        ],
        dispatchCanonical: conversation.assistantMembership != null,
        suppressAssistant: !_assistantActive(conversation),
      ),
    );
    return true;
  }
}

/// The expanded dock composer's capsule row: the Assistant identity capsule
/// and the Adaptive Flywheel capsule, popping in above the field with a short
/// rise-and-fade when the row appears.
final class _DockComposerCapsuleRow extends StatelessWidget {
  const _DockComposerCapsuleRow({
    super.key,
    required this.conversation,
    required this.canonical,
    required this.turns,
    required this.agentsProjection,
    required this.assistantActive,
    required this.onToggleAssistant,
    required this.onEditAssistant,
    required this.onOpenFlywheel,
  });

  final ClientConversation conversation;
  final CanonicalConversationProjection canonical;
  final PersistentTurnProjection turns;
  final AgentsProjection agentsProjection;
  final bool assistantActive;
  final VoidCallback onToggleAssistant;
  final VoidCallback onEditAssistant;
  final ValueChanged<String?> onOpenFlywheel;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final allTargets = agentsProjection.targetDetails;
    final participantTargets = resolveCanonicalGroupParticipantTargets(
      conversation,
      allTargets,
    );
    final membership = conversation.assistantMembership;
    TargetCandidate? assistantTarget;
    if (membership != null) {
      for (final target
          in participantTargets.isEmpty ? allTargets : participantTargets) {
        if (target.target == membership.principal.agentId) {
          assistantTarget = target;
          break;
        }
      }
    }
    final assistantLabel = membership == null
        ? strings.assistantNeedsConfigurationStatus
        : canonicalGroupAssistantCapsuleLabel(
            membership,
            assistantTarget ??
                TargetCandidate(
                  target: membership.principal.agentId,
                  label: membership.principal.displayName,
                  kind: 'agent',
                  status: TargetCandidateStatus.unavailable,
                  configured: false,
                  confidence: 0,
                  adapterStatus: 'runtime-unavailable',
                ),
          );
    final status = canonicalGroupAssistantStatus(
      conversation: conversation,
      assistantActive: assistantActive,
      canonical: canonical,
      turns: turns,
    );
    final revision = conversation.strategyRevision.trim();
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: LicoMotion.medium,
      curve: LicoMotion.decelerate,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - t)),
          child: child,
        ),
      ),
      child: Row(
        children: [
          AssistantToggleButton(
            active: assistantActive,
            configured: membership != null,
            label: assistantLabel,
            status: status,
            onTap: onToggleAssistant,
            onEdit: onEditAssistant,
          ),
          const SizedBox(width: 8),
          GroupStrategyPickerCapsule(
            selectedRevision: revision.isEmpty ? null : revision,
            onOpen: onOpenFlywheel,
          ),
        ],
      ),
    );
  }
}

/// Shell chrome status/locale fed by the runtime-backed shell sources.
///
/// Seeded from the already-admitted snapshots when they exist, then advanced
/// only by admitted source changes. A revoked or failing region clears the
/// status instead of falling back to the raw projection owner.
final class _BindingLayoutChrome implements LayoutChromePort {
  _BindingLayoutChrome({
    required PresentationRuntime runtime,
    required PresentationSource<StatusProjection> status,
    required PresentationSource<LocaleProjection> locale,
    required MobileRelayBinding mobileRelay,
    required SearchBinding search,
  }) : _mobileRelay = mobileRelay,
       _search = search {
    _status = runtime.current(status.fieldGroup)?.value;
    _locale = runtime.current(locale.fieldGroup)?.value;
    _value = _compose();
    final statusObservation = runtime.observe(status);
    _statusSubscription = statusObservation.stream.listen(
      (snapshot) {
        _status = snapshot.value;
        _publish();
      },
      onError: (Object error, StackTrace stack) {
        _status = null;
        _publish();
      },
    );
    final localeObservation = runtime.observe(locale);
    _localeSubscription = localeObservation.stream.listen(
      (snapshot) {
        _locale = snapshot.value;
        _publish();
      },
      onError: (Object error, StackTrace stack) {
        _locale = null;
        _publish();
      },
    );
    _statusObservation = statusObservation;
    _localeObservation = localeObservation;
  }

  final MobileRelayBinding _mobileRelay;
  final SearchBinding _search;
  final _RendererNotifier _listeners = _RendererNotifier();
  StatusProjection? _status;
  LocaleProjection? _locale;
  late final ResourceObservationSubscription<StatusProjection>
  _statusObservation;
  late final ResourceObservationSubscription<LocaleProjection>
  _localeObservation;
  late final StreamSubscription<ResourceSnapshot<StatusProjection>>
  _statusSubscription;
  late final StreamSubscription<ResourceSnapshot<LocaleProjection>>
  _localeSubscription;
  late LayoutChromeSnapshot _value;
  bool _disposed = false;

  @override
  LayoutChromeSnapshot get value => _value;

  @override
  void addListener(VoidCallback listener) => _listeners.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _listeners.removeListener(listener);

  @override
  Future<void> openPairing(BuildContext context) =>
      showMobileRelayPopup(context, _mobileRelay);

  @override
  Future<void> openGlobalSearch(BuildContext context) =>
      showAgentConversationSearchPalette(context, _search);

  LayoutChromeSnapshot _compose() {
    final status = _status;
    final locale = _locale;
    if (status == null || locale == null) {
      return const LayoutChromeSnapshot.empty();
    }
    return _snapshot(status, locale);
  }

  void _publish() {
    if (_disposed) return;
    final next = _compose();
    if (next == _value) return;
    _value = next;
    _listeners.publish();
  }

  static LayoutChromeSnapshot _snapshot(
    StatusProjection projection,
    LocaleProjection locale,
  ) {
    final resolved = resolveStatusProjection(projection, locale);
    return LayoutChromeSnapshot(
      status: LayoutChromeStatusSnapshot(
        message: resolved.message,
        caption: resolved.caption,
        errorCode: resolved.errorCode,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      _statusSubscription.cancel(),
      _localeSubscription.cancel(),
    ]);
    await Future.wait([_statusObservation.close(), _localeObservation.close()]);
    _listeners.dispose();
  }
}

final class _RendererNotifier extends ChangeNotifier {
  void publish() => notifyListeners();
}
