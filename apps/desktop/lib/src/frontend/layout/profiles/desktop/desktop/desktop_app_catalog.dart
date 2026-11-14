import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_desktop_copy.dart';

/// Every built-in app the Desktop work area can host. The conversation is not
/// an app: it occupies the chat sidebar permanently. Plugin windows are not
/// listed here; they come from the installed-plugin catalog at runtime.
enum DesktopAppId {
  collaboration,
  agentHub,
  monitoring,
  modelsGateway,
  devices,
  skillHub,
  modelsChatChannels,
  pluginCenter,
  settings,
}

/// The arrangeable built-in group of the dock in catalog order. Every app in
/// it is always present in the dock; the user owns the order and folders.
const List<DesktopAppId> desktopDockApps = <DesktopAppId>[
  DesktopAppId.collaboration,
  DesktopAppId.agentHub,
  DesktopAppId.monitoring,
  DesktopAppId.modelsGateway,
  DesktopAppId.devices,
];

/// The fixed trailing group of the dock.
const List<DesktopAppId> desktopDockSystemApps = <DesktopAppId>[
  DesktopAppId.pluginCenter,
  DesktopAppId.settings,
];

/// The app the work area shows when nothing else is open.
const DesktopAppId desktopDefaultApp = DesktopAppId.collaboration;

/// The destination hosting [app]; null for apps that are chrome features
/// rather than destinations.
ClientSection? desktopAppSection(DesktopAppId app) => switch (app) {
  DesktopAppId.collaboration => null,
  DesktopAppId.agentHub => ClientSection.agentHub,
  DesktopAppId.skillHub => ClientSection.skillHub,
  DesktopAppId.pluginCenter => ClientSection.pluginManagement,
  DesktopAppId.monitoring => ClientSection.monitoring,
  DesktopAppId.modelsGateway => ClientSection.models,
  DesktopAppId.devices => ClientSection.devices,
  DesktopAppId.modelsChatChannels => ClientSection.models,
  DesktopAppId.settings => ClientSection.settings,
};

/// The app hosted by [section]; the models destination resolves through
/// [desktopModelsAppForPane] instead.
DesktopAppId? desktopAppForSection(ClientSection section) {
  for (final app in DesktopAppId.values) {
    if (desktopAppSection(app) == section) return app;
  }
  return null;
}

/// The models-destination pane this app selects, when it targets one. Both
/// models apps share the retained communication pane channel: 0 selects
/// Model Gateway, 1 selects Chat Channels.
int? desktopAppModelsPane(DesktopAppId app) => switch (app) {
  DesktopAppId.modelsGateway => 0,
  DesktopAppId.modelsChatChannels => 1,
  _ => null,
};

/// The app occupying a models destination, mirrored from
/// [desktopAppModelsPane].
DesktopAppId desktopModelsAppForPane(int pane) => switch (pane) {
  1 => DesktopAppId.modelsChatChannels,
  _ => DesktopAppId.modelsGateway,
};

IconData desktopAppIcon(DesktopAppId app) => switch (app) {
  DesktopAppId.collaboration => Icons.account_tree_outlined,
  DesktopAppId.agentHub => Icons.auto_awesome_outlined,
  DesktopAppId.skillHub => Icons.library_books_outlined,
  DesktopAppId.pluginCenter => Icons.layers_outlined,
  DesktopAppId.monitoring => Icons.query_stats_outlined,
  DesktopAppId.modelsGateway => Icons.hub_outlined,
  DesktopAppId.devices => Icons.smartphone_outlined,
  DesktopAppId.modelsChatChannels => Icons.forum_outlined,
  DesktopAppId.settings => Icons.settings_outlined,
};

String desktopAppLabel(LicoStrings strings, DesktopAppId app) => switch (app) {
  DesktopAppId.collaboration => strings.collaborationTitle,
  DesktopAppId.agentHub => strings.agentHub,
  DesktopAppId.skillHub => strings.skillsNav,
  DesktopAppId.pluginCenter => DesktopDesktopCopy.pluginCenterLabel(strings),
  DesktopAppId.monitoring => strings.tokenUsage,
  DesktopAppId.modelsGateway => strings.modelGateway,
  DesktopAppId.devices => strings.devices,
  DesktopAppId.modelsChatChannels => strings.chatChannels,
  DesktopAppId.settings => strings.settings,
};

/// Decodes a persisted app name; unknown names decode to null so stored
/// layouts drop them silently.
DesktopAppId? desktopAppByName(String name) {
  for (final app in DesktopAppId.values) {
    if (app.name == name) return app;
  }
  return null;
}

/// What the work area shows: a built-in app or one plugin window.
sealed class DesktopWorkItem {
  const DesktopWorkItem();

  /// Stable identity shared by dock keys and quick-switcher app ids.
  String get id;
}

final class DesktopWorkApp extends DesktopWorkItem {
  const DesktopWorkApp(this.app);

  final DesktopAppId app;

  @override
  String get id => 'app:${app.name}';

  @override
  bool operator ==(Object other) => other is DesktopWorkApp && other.app == app;

  @override
  int get hashCode => app.hashCode;
}

final class DesktopWorkPlugin extends DesktopWorkItem {
  const DesktopWorkPlugin(this.pluginId);

  final String pluginId;

  @override
  String get id => 'plugin:$pluginId';

  @override
  bool operator ==(Object other) =>
      other is DesktopWorkPlugin && other.pluginId == pluginId;

  @override
  int get hashCode => pluginId.hashCode;
}

/// Decodes a [DesktopWorkItem.id].
DesktopWorkItem? desktopWorkItemById(String id) {
  if (id.startsWith('app:')) {
    final app = desktopAppByName(id.substring(4));
    return app == null ? null : DesktopWorkApp(app);
  }
  if (id.startsWith('plugin:') && id.length > 7) {
    return DesktopWorkPlugin(id.substring(7));
  }
  return null;
}
