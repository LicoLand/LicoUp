import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/binding_shell_renderer/shell_chrome_features.dart';
import 'package:licoup/src/composition/binding_shell_renderer/shell_destinations.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

/// Concrete renderer factory assembled only at the composition boundary.
///
/// The shell chrome consumes the runtime-backed presentation sources: the
/// application-scope [PresentationRuntime] owns source observation and
/// authority revocation, so the renderer never reads the raw projection
/// owners directly and never re-serves a withdrawn value.
///
/// This class owns the constructor, the assembly it delegates to and the
/// disposal order; the destination panels live in `shell_destinations.dart`,
/// the chrome assembly and its notices exposure live in
/// `shell_chrome_features.dart`, and the dock composer lives in
/// `shell_dock_composer.dart`.
///
/// A binding for an optional feature is nullable: the composition passes null
/// for a feature it did not install. That feature's own destination then
/// renders an empty surface instead of a conditional inside this class, and
/// the agents destination, which the minimum composition always serves, hands
/// the workspace the relay feature's absent value instead of a null.
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
    required SkillHubBinding? skillHub,
    required PluginManagementBinding? pluginManagement,
    required MobileRelayBinding? mobileRelay,
    required ModelsBinding? models,
    required SettingsBinding? settings,
    required AgentHubBinding? agentHub,
    required SearchBinding? search,
    required TargetsBinding targets,
    required ExternalUriOpener openExternalUri,
    required String workspaceHomeDirectory,
  }) : _layout = layout,
       _runtime = runtime,
       _chromeSource = chromeSource,
       _agents = agents,
       _conversation = conversation,
       _chrome = ShellLayoutChrome(
         runtime: runtime,
         status: statusSource,
         locale: localeSource,
         mobileRelay: mobileRelay,
         search: search,
       ),
       _destinations = ShellDestinations(
         layout: layout,
         shellIntents: shellIntents,
         agents: agents,
         conversation: conversation,
         monitoring: monitoring,
         mobileRelay: mobileRelay,
         targets: targets,
         openExternalUri: openExternalUri,
         workspaceHomeDirectory: workspaceHomeDirectory,
         skillHub: skillHub,
         pluginManagement: pluginManagement,
         models: models,
         settings: settings,
         agentHub: agentHub,
       );

  final BuiltInLayoutComposition _layout;
  final PresentationRuntime _runtime;
  final PresentationSource<ChromeProjection> _chromeSource;
  final AgentsBinding _agents;
  final ConversationBinding _conversation;
  final ShellLayoutChrome _chrome;
  final ShellDestinations _destinations;
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
  ) => ShellChromeFeatures(
    runtime: _runtime,
    chromeSource: _chromeSource,
    agents: _agents,
    conversation: _conversation,
    auxChromePanelOpen: auxChromePanelOpen,
  );

  @override
  GlobalKey createAgentsHomeKey() => _destinations.createAgentsHomeKey();

  @override
  Widget buildDestination(
    BuildContext context,
    ClientSection destination, {
    required GlobalKey agentsHomeKey,
  }) => _destinations.build(context, destination, agentsHomeKey: agentsHomeKey);

  @override
  void resetAgentsHome(GlobalKey agentsHomeKey) =>
      _destinations.resetAgentsHome(agentsHomeKey);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _chrome.dispose();
  }
}
