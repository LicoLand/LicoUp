import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/composition/binding_shell_renderer/shell_destinations.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/chrome_feature_apps.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/work_control_presentation.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_state_port.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_quick_switcher.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_member_profile_card.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/package_recommendation_sheet_host.dart';
import 'package:licoup/src/frontend/features/plugin_window/ui/plugin_window_actions.dart';
import 'package:licoup/src/frontend/features/plugin_window/ui/plugin_window_view.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/projects/project_plan_submission.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_self_avatar.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/devices/devices_binding.dart';
import 'package:licoup/src/presentation/models/models_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_binding.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/presentation/projects/projects_binding.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

typedef ExternalUriOpener = Future<void> Function(Uri uri);

/// Concrete renderer factory assembled only at the composition boundary.
final class BindingShellRenderer implements ShellRendererPort {
  BindingShellRenderer({
    required ClientCompositionSet composition,
    required BuiltInLayoutComposition layout,
    required IntentSink<ShellIntent> shellIntents,
    required ProjectionSource<StatusProjection> status,
    required ProjectionSource<LocaleProjection> locale,
    required AgentsBinding agents,
    required ChromeBinding chrome,
    required ConversationBinding conversation,
    required MonitoringBinding monitoring,
    required SkillHubBinding? skillHub,
    required PluginManagementBinding? pluginManagement,
    required DevicesBinding? devices,
    required ModelsBinding? models,
    required SettingsBinding? settings,
    required AgentHubBinding? agentHub,
    required SearchBinding? search,
    required TargetsBinding targets,
    required PluginWindowBinding pluginWindow,
    required CollaborationBindingFor collaborationFor,
    required CollaborationBindingRelease releaseCollaboration,
    required ExternalUriOpener openExternalUri,
    required String workspaceHomeDirectory,
    required this.workControl,
    required this.projects,
    required this.projectPlanSubmission,
    ClientUpdateAdmission Function()? clientUpdateAdmission,
  }) : _layout = layout,
       _agents = agents,
       _chromeBinding = chrome,
       _conversation = conversation,
       _pluginWindow = pluginWindow,
       _collaborationFor = collaborationFor,
       _releaseCollaboration = releaseCollaboration,
       _destinations = ShellDestinations(
         composition: composition,
         layout: layout,
         shellIntents: shellIntents,
         agents: agents,
         conversation: conversation,
         monitoring: monitoring,
         targets: targets,
         openExternalUri: openExternalUri,
         workspaceHomeDirectory: workspaceHomeDirectory,
         clientUpdateAdmission:
             clientUpdateAdmission ?? clientUpdateAdmissionUnavailable,
         skillHub: skillHub,
         pluginManagement: pluginManagement,
         models: models,
         settings: settings,
         agentHub: agentHub,
         devices: devices,
         projects: projects,
         projectPlanSubmission: projectPlanSubmission,
       ),
       _chrome = _BindingLayoutChrome(
         status: status,
         locale: locale,
         search: search,
       );

  final BuiltInLayoutComposition _layout;
  final AgentsBinding _agents;
  final ChromeBinding _chromeBinding;
  final ConversationBinding _conversation;
  final PluginWindowBinding _pluginWindow;
  final CollaborationBindingFor _collaborationFor;
  final CollaborationBindingRelease _releaseCollaboration;
  late final ShellDestinations _destinations;

  /// The runtime work-control presentation, here so the conversation composer
  /// can show the live work item stop state.
  final WorkControlPresentation workControl;

  /// The projects binding, null when the composition does not mount it.
  final ProjectsBinding? projects;

  /// The project-plan submission port wired into the composition.
  final ProjectPlanSubmission projectPlanSubmission;

  /// The feature-mounted destination map this renderer answers to.
  ShellDestinations get destinations => _destinations;
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
    pluginWindow: _pluginWindow,
    collaborationFor: _collaborationFor,
    releaseCollaboration: _releaseCollaboration,
    auxChromePanelOpen: auxChromePanelOpen,
  );

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) =>
      _destinations.build(context, destination);

  /// The binding shell wraps every mounted surface with the first-launch
  /// package recommendation host, which reads the plugin-management binding.
  /// An unmounted plugin-management feature has no recommendation surface.
  @override
  Widget wrapShellContent(BuildContext context, Widget child) {
    final pluginManagement = _destinations.pluginManagement;
    return pluginManagement == null
        ? child
        : PackageRecommendationSheetHost(
            binding: pluginManagement,
            child: child,
          );
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
    required this.pluginWindow,
    required CollaborationBindingFor collaborationFor,
    required CollaborationBindingRelease releaseCollaboration,
    required this.auxChromePanelOpen,
  }) : notificationNotices = _ChromeNoticesListenable(
         projection: chrome.projection,
       ),
       collaborationApp = CollaborationAppFollower(
         conversation: conversation,
         bindingFor: collaborationFor,
         release: releaseCollaboration,
       ),
       pluginWindows = PluginWindowSummaries(
         projection: pluginWindow.projection,
       );

  final AgentsBinding agents;
  final ChromeBinding chrome;
  final ConversationBinding conversation;
  final PluginWindowBinding pluginWindow;

  @override
  final ValueListenable<LicoToastNoticesSnapshot> notificationNotices;

  @override
  final ValueNotifier<bool> auxChromePanelOpen;

  @override
  final CollaborationAppFollower collaborationApp;

  @override
  final PluginWindowSummaries pluginWindows;

  @override
  void activateOperationNotice(ChromeOperationNotificationProjection notice) {
    final target = notice.completionTarget;
    if (target == null) return;
    conversation.intents.send(
      ActivateContinuityCompletionNotice(notificationId: target.notificationId),
    );
  }

  @override
  Widget buildCollaborationApp(BuildContext context) =>
      CollaborationAppSurface(follower: collaborationApp);

  @override
  void openPluginWindow(String pluginId) =>
      pluginWindow.intents.send(OpenPluginWindow(pluginId));

  @override
  void closePluginWindow(String pluginId) =>
      pluginWindow.intents.send(ClosePluginWindow(pluginId));

  @override
  Widget buildPluginWindow(BuildContext context, String pluginId) =>
      PluginWindowView(binding: pluginWindow, pluginId: pluginId);

  @override
  Widget buildPluginWindowActions(
    BuildContext context,
    String pluginId, {
    required VoidCallback onOpenPermissionSettings,
    required VoidCallback onClose,
  }) => PluginWindowTitleActions(
    binding: pluginWindow,
    pluginId: pluginId,
    onOpenPermissionSettings: onOpenPermissionSettings,
    onClose: onClose,
  );

  @override
  Future<void> openQuickSwitcher(
    BuildContext context, {
    required List<LayoutQuickSwitcherApp> apps,
    required ValueChanged<String> onOpenApp,
  }) => showConversationQuickSwitcher(
    context,
    agents: agents,
    conversation: conversation,
    apps: apps,
    onOpenApp: onOpenApp,
  );

  @override
  Widget buildSelfAvatar(
    BuildContext context, {
    required double size,
    String? mascotId,
  }) => MessagingSelfAvatar(size: size, mascotId: mascotId);

  @override
  Future<void> openSelfProfile(
    BuildContext context, {
    required Rect anchorRect,
    String? mascotId,
    required ValueChanged<String> onMascotChanged,
    required VoidCallback onOpenSettings,
  }) => showMessagingMemberProfile(
    context: context,
    anchorRect: anchorRect,
    card: MessagingSelfProfileCard(
      displayName: LicoStrings.of(context).localUser,
      mascotId: mascotId,
      onMascotChanged: onMascotChanged,
      onOpenSettings: onOpenSettings,
    ),
  );
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

final class _BindingLayoutChrome implements LayoutChromePort {
  _BindingLayoutChrome({
    required ProjectionSource<StatusProjection> status,
    required ProjectionSource<LocaleProjection> locale,
    required SearchBinding? search,
  }) : _search = search {
    _status = status.current;
    _locale = locale.current;
    _value = _snapshot(_status, _locale);
    _statusSubscription = status.changes.listen(_handleStatus);
    _localeSubscription = locale.changes.listen(_handleLocale);
  }

  final SearchBinding? _search;
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

  /// Opens global search only when the search feature is installed; an absent
  /// search binding has no search surface and no owner to reach.
  @override
  Future<void> openGlobalSearch(BuildContext context) {
    final search = _search;
    return search == null
        ? Future<void>.value()
        : showAgentConversationSearchPalette(context, search);
  }

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
