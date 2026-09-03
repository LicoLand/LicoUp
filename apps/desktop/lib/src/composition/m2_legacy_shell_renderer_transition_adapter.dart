import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/agents/ui/agents_canvas.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_chrome_tabs.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_notification_bell.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/features/models/ui/models_panel.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

/// Temporary one-way bridge for the eight controller-based feature bodies.
final class M2LegacyShellRendererTransitionAdapter
    implements ShellRendererPort {
  M2LegacyShellRendererTransitionAdapter(
    this._controller,
    this._intents,
    ProjectionSource<ShellProjection> projection,
  ) : _chrome = _M2LayoutChromeAdapter(_controller, projection);

  final ClientController _controller;
  final IntentSink<ShellIntent> _intents;
  final _M2LayoutChromeAdapter _chrome;

  @override
  LayoutRegistry get layoutRegistry => _controller.layoutComposition.registry;

  @override
  LayoutStateStore get layoutStateStore =>
      _controller.layoutComposition.stateStore;

  @override
  LayoutChromePort get chrome => _chrome;

  @override
  LayoutChromeFeatures createChromeFeatures(
    ValueNotifier<bool> auxChromePanelOpen,
  ) => _M2ChromeFeatures(_controller, auxChromePanelOpen);

  @override
  GlobalKey createAgentsHomeKey() => GlobalKey<MobileAgentsHomeState>();

  @override
  Widget buildDestination(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  }) => switch (destination) {
    ClientSection.agents => AgentsCanvas(
      controller: _controller,
      agentsHomeKey: agentsHomeKey as GlobalKey<MobileAgentsHomeState>,
    ),
    ClientSection.monitoring => AgentUsagePanel(controller: _controller),
    ClientSection.skillHub => SkillHubPanel(controller: _controller),
    ClientSection.pluginManagement => AdapterPluginPanel(
      controller: _controller,
    ),
    ClientSection.mobileRelay => MobileRelayPanel(controller: _controller),
    ClientSection.models => ModelsPanel(
      controller: _controller,
      pane: modelsPanelPaneOf(context),
    ),
    ClientSection.settings => SettingsPanel(controller: _controller),
    ClientSection.agentHub => AgentHubPanel(
      controller: _controller.agentHubCatalogController,
      openHomepage: _controller.runtimePlatformBridge.openHttps,
      onOpenAgent: (agentId) => _intents.send(OpenShellAgent(agentId)),
    ),
  };

  @override
  void resetAgentsHome(GlobalKey agentsHomeKey) {
    final state = agentsHomeKey.currentState;
    if (state is MobileAgentsHomeState) state.resetToList();
  }

  Future<void> dispose() => _chrome.dispose();
}

final class _M2ChromeFeatures implements LayoutChromeFeatures {
  _M2ChromeFeatures(this._controller, this._auxChromePanelOpen);

  final ClientController _controller;
  final ValueNotifier<bool> _auxChromePanelOpen;

  @override
  ValueNotifier<bool> get auxChromePanelOpen => _auxChromePanelOpen;

  @override
  Widget buildConversationTabs(BuildContext context) =>
      MessagingConversationTabStrip(
        controller: _controller,
        onCloseAuxChromePanel: _close,
      );

  @override
  Widget buildNotificationBell(BuildContext context) =>
      MessagingNotificationBell(
        controller: _controller,
        onCloseAuxChromePanel: _close,
      );

  void _close() => _auxChromePanelOpen.value = false;
}

final class _M2LayoutChromeAdapter implements LayoutChromePort {
  _M2LayoutChromeAdapter(this._controller, this._projection) {
    _subscription = _projection.changes.listen(_handleChanged);
    _value = _snapshot(_projection.current);
  }

  final ClientController _controller;
  final ProjectionSource<ShellProjection> _projection;
  final _LayoutChromeNotifier _listeners = _LayoutChromeNotifier();
  late final StreamSubscription<ShellProjection> _subscription;
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
      showMobileRelayPopup(context, _controller);

  @override
  Future<void> openGlobalSearch(BuildContext context) async {
    final strings = LicoStrings.of(context);
    showAgentConversationSearchPalette(
      context,
      _controller,
      features: buildGlobalSearchFeatures(
        strings: strings,
        onSelectSection: _controller.selectSection,
        onNewConversation: _controller.startNewConversationSession,
      ),
      settingsFeatures: buildSettingsSearchFeatures(
        strings: strings,
        onOpenSettings: () => _controller.selectSection(ClientSection.settings),
      ),
      agentFeatures: buildAgentSearchFeatures(
        targets: _controller.scannedTargets,
        onOpenAgentHub: () => _controller.selectSection(ClientSection.agentHub),
      ),
      pluginFeatures: buildPluginSearchFeatures(
        adapters: _controller.adapterPluginController.adapters,
        onOpenPlugins: () =>
            _controller.selectSection(ClientSection.pluginManagement),
      ),
    );
  }

  void _handleChanged(ShellProjection projection) {
    if (_disposed) return;
    final next = _snapshot(projection);
    if (next == _value) return;
    _value = next;
    _listeners.publish();
  }

  static LayoutChromeSnapshot _snapshot(ShellProjection projection) =>
      LayoutChromeSnapshot(
        status: LayoutChromeStatusSnapshot(
          message: projection.status.displayMessage,
          caption: projection.status.displayCaption,
          errorCode: projection.status.errorCode,
        ),
      );

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    _listeners.dispose();
  }
}

final class _LayoutChromeNotifier extends ChangeNotifier {
  void publish() => notifyListeners();
}
