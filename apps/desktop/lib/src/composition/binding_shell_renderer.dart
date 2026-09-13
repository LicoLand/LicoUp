import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
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
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
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
final class BindingShellRenderer implements ShellRendererPort {
  BindingShellRenderer({
    required BuiltInLayoutComposition layout,
    required IntentSink<ShellIntent> shellIntents,
    required ProjectionSource<StatusProjection> status,
    required ProjectionSource<LocaleProjection> locale,
    required AgentsBinding agents,
    required ChromeBinding chrome,
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
       _agents = agents,
       _chromeBinding = chrome,
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
         status: status,
         locale: locale,
         mobileRelay: mobileRelay,
         search: search,
       );

  final BuiltInLayoutComposition _layout;
  final IntentSink<ShellIntent> _shellIntents;
  final AgentsBinding _agents;
  final ChromeBinding _chromeBinding;
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
    agents: _agents,
    chrome: _chromeBinding,
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
    ClientSection.agentHub => AgentHubPanel(
      binding: _agentHub,
      plugins: _pluginManagement,
      skills: _skillHub,
      openHomepage: _openExternalUri,
      onOpenAgent: (agentId) => _shellIntents.send(OpenShellAgent(agentId)),
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

final class _BindingChromeFeatures implements LayoutChromeFeatures {
  _BindingChromeFeatures({
    required this.agents,
    required this.chrome,
    required this.conversation,
    required this.auxChromePanelOpen,
  }) : notificationNotices = _ChromeNoticesListenable(
         projection: chrome.projection,
       );

  final AgentsBinding agents;
  final ChromeBinding chrome;
  final ConversationBinding conversation;

  @override
  final ValueListenable<LicoToastNoticesSnapshot> notificationNotices;

  @override
  final ValueNotifier<bool> auxChromePanelOpen;

  @override
  Widget buildDockComposer(BuildContext context) =>
      _DockConversationComposer(agents: agents, conversation: conversation);

  @override
  void activateOperationNotice(ChromeOperationNotificationProjection notice) {
    final target = notice.completionTarget;
    if (target == null) return;
    conversation.intents.send(
      ActivateContinuityCompletionNotice(notificationId: target.notificationId),
    );
  }
}

/// Maps the chrome projection to the toast notices snapshot on demand.
/// Listeners subscribe straight to the projection's change stream, so the
/// exposure owns no persistent subscription of its own.
final class _ChromeNoticesListenable
    implements ValueListenable<LicoToastNoticesSnapshot> {
  _ChromeNoticesListenable({required this.projection});

  final ProjectionSource<ChromeProjection> projection;
  final Map<
    VoidCallback,
    StreamSubscription<ProjectionUpdate<ChromeProjection>>
  >
  _subscriptions =
      <VoidCallback, StreamSubscription<ProjectionUpdate<ChromeProjection>>>{};

  @override
  LicoToastNoticesSnapshot get value => _snapshot(projection.current);

  @override
  void addListener(VoidCallback listener) {
    if (_subscriptions.containsKey(listener)) return;
    _subscriptions[listener] = projection.changes.listen((_) => listener());
  }

  @override
  void removeListener(VoidCallback listener) {
    final subscription = _subscriptions.remove(listener);
    if (subscription == null) return;
    unawaited(subscription.cancel());
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

/// The conversation composer re-parented into the Desktop dock capsule. Sends
/// through the same conversation intents as the in-workspace composer; the
/// Desktop shell hides the workspace's internal composer while this is
/// hosted. Mounts nothing when no conversation can accept input.
final class _DockConversationComposer extends StatelessWidget {
  const _DockConversationComposer({
    required this.agents,
    required this.conversation,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<ComposerProjection, ComposerProjection>(
      source: conversation.composer,
      select: (projection) => projection,
      builder: (context, composer) =>
          ProjectionBuilder<PersistentTurnProjection, PersistentTurnProjection>(
            source: conversation.persistentTurns,
            select: (projection) => projection,
            builder: (context, turns) =>
                ProjectionBuilder<
                  ConversationAttachmentsProjection,
                  ConversationAttachmentsProjection
                >(
                  source: conversation.attachments,
                  select: (projection) => projection,
                  builder: (context, attachments) =>
                      ProjectionBuilder<
                        ConversationProjection,
                        ConversationProjection
                      >(
                        source: conversation.projection,
                        select: (projection) => projection,
                        builder: (context, root) =>
                            ProjectionBuilder<
                              CanonicalConversationProjection,
                              CanonicalConversationProjection
                            >(
                              source: conversation.canonicalEvents,
                              select: (projection) => projection,
                              builder: (context, canonical) =>
                                  ProjectionBuilder<
                                    AgentsProjection,
                                    AgentsProjection
                                  >(
                                    source: agents.projection,
                                    select: (projection) => projection,
                                    builder: (context, agentsProjection) =>
                                        _buildComposer(
                                          context,
                                          composer: composer,
                                          turns: turns,
                                          attachments: attachments,
                                          root: root,
                                          canonical: canonical,
                                          agentsProjection: agentsProjection,
                                        ),
                                  ),
                            ),
                      ),
                ),
          ),
    );
  }

  Widget _buildComposer(
    BuildContext context, {
    required ComposerProjection composer,
    required PersistentTurnProjection turns,
    required ConversationAttachmentsProjection attachments,
    required ConversationProjection root,
    required CanonicalConversationProjection canonical,
    required AgentsProjection agentsProjection,
  }) {
    final strings = LicoStrings.of(context);
    final turn = turns.memberships.isEmpty ? null : turns.memberships.first;
    final turnActive =
        turn?.phase == PersistentTurnPhase.running ||
        turn?.phase == PersistentTurnPhase.waiting;

    final canonicalConversation =
        root.authority == ConversationAuthority.canonicalConversation
        ? canonical.conversation
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

    if (canonicalConversation != null) {
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
          turns.memberships.every((membership) => membership.inputEnabled);
      busy = canonical.sending || turnActive;
      onSend = (content) => _sendCanonical(
        conversation: group,
        composer: composer,
        attachments: attachments,
        content: content,
      );
      final cancellable = turns.memberships
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
    } else {
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
    }

    return RuntimeMessageComposer(
      // Same keying rule as the in-workspace composer: a conversation switch
      // starts a fresh composer state seeded from that conversation's draft.
      key: ValueKey<String>('dock-composer-${composer.conversationId}'),
      targetLabel: targetLabel,
      initialDraft: composer.draft,
      hasAttachments: attachments.attachments.isNotEmpty,
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
      floatingMatteCapsule: true,
      onPasteImage: attachments.acceptsImages
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
  }

  Future<bool> _sendCanonical({
    required ClientConversation conversation,
    required ComposerProjection composer,
    required ConversationAttachmentsProjection attachments,
    required String content,
  }) async {
    if (attachments.attachments.isNotEmpty && !attachments.acceptsImages) {
      this.conversation.intents.send(
        const SurfaceConversationFailure(
          stage: 'send',
          reasonCode: 'attachment_transport_unsupported',
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
      ),
    );
    return true;
  }
}

final class _BindingLayoutChrome implements LayoutChromePort {
  _BindingLayoutChrome({
    required ProjectionSource<StatusProjection> status,
    required ProjectionSource<LocaleProjection> locale,
    required MobileRelayBinding mobileRelay,
    required SearchBinding search,
  }) : _mobileRelay = mobileRelay,
       _search = search {
    _status = status.current;
    _locale = locale.current;
    _value = _snapshot(_status, _locale);
    _statusSubscription = status.changes.listen(_handleStatus);
    _localeSubscription = locale.changes.listen(_handleLocale);
  }

  final MobileRelayBinding _mobileRelay;
  final SearchBinding _search;
  final _RendererNotifier _listeners = _RendererNotifier();
  late StatusProjection _status;
  late LocaleProjection _locale;
  late final StreamSubscription<ProjectionUpdate<StatusProjection>>
  _statusSubscription;
  late final StreamSubscription<ProjectionUpdate<LocaleProjection>>
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

  void _handleStatus(ProjectionUpdate<StatusProjection> update) {
    if (_disposed) return;
    _status = update.value;
    final next = _snapshot(_status, _locale);
    if (next == _value) return;
    _value = next;
    _listeners.publish();
  }

  void _handleLocale(ProjectionUpdate<LocaleProjection> update) {
    if (_disposed) return;
    _locale = update.value;
    final next = _snapshot(_status, _locale);
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
    _listeners.dispose();
  }
}

final class _RendererNotifier extends ChangeNotifier {
  void publish() => notifyListeners();
}
