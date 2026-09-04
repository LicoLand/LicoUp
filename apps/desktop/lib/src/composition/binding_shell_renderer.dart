import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/environment/workspace_home_directory_scope.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_notification_bell.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/features/models/ui/models_panel.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
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
    ClientSection.monitoring => AgentUsagePanel(
      binding: _monitoring,
      onExit: () => _shellIntents.send(
        const SelectShellDestination(ClientSection.agents),
      ),
    ),
    ClientSection.skillHub => SkillHubPanel(binding: _skillHub),
    ClientSection.pluginManagement => AdapterPluginPanel(
      binding: _pluginManagement,
    ),
    ClientSection.mobileRelay => MobileRelayPanel(binding: _mobileRelay),
    ClientSection.models => ModelsPanel(
      binding: _models,
      pane: modelsPanelPaneOf(context),
    ),
    ClientSection.settings => SettingsPanel(
      binding: _settings,
      layoutRegistry: _layout.registry,
    ),
    ClientSection.agentHub => AgentHubPanel(
      binding: _agentHub,
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
  const _BindingChromeFeatures({
    required this.agents,
    required this.chrome,
    required this.conversation,
    required this.auxChromePanelOpen,
  });

  final AgentsBinding agents;
  final ChromeBinding chrome;
  final ConversationBinding conversation;

  @override
  final ValueNotifier<bool> auxChromePanelOpen;

  @override
  Widget buildConversationTabs(BuildContext context) =>
      MessagingConversationTabStrip(
        agents: agents,
        conversation: conversation,
        onCloseAuxChromePanel: _close,
      );

  @override
  Widget buildNotificationBell(BuildContext context) =>
      MessagingNotificationBell(chrome: chrome, onCloseAuxChromePanel: _close);

  void _close() => auxChromePanelOpen.value = false;
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
