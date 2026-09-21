import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Every app the Desktop shell can host in its left pane. 对话 is not a dock
/// app: the conversation occupies the right pane permanently, so it never
/// appears in the icon strip or the features grid. 设置 and the 功能 grid are
/// pinned strip affordances, not catalog apps.
enum DesktopAppId {
  agentHub,
  skillHub,
  pluginManagement,
  monitoring,
  modelsGateway,
  mobileRelay,
  modelsChatChannels,
}

/// The visible feature apps in frozen catalog order.
const List<DesktopAppId> desktopFeatureApps = <DesktopAppId>[
  DesktopAppId.agentHub,
  DesktopAppId.monitoring,
  DesktopAppId.modelsGateway,
  DesktopAppId.mobileRelay,
];

ClientSection desktopAppSection(DesktopAppId app) => switch (app) {
  DesktopAppId.agentHub => ClientSection.agentHub,
  DesktopAppId.skillHub => ClientSection.skillHub,
  DesktopAppId.pluginManagement => ClientSection.pluginManagement,
  DesktopAppId.monitoring => ClientSection.monitoring,
  DesktopAppId.modelsGateway => ClientSection.models,
  DesktopAppId.mobileRelay => ClientSection.mobileRelay,
  DesktopAppId.modelsChatChannels => ClientSection.models,
};

/// The models-destination pane this app selects, when it targets one. Both
/// models apps share the retained communication pane channel (frozen
/// contract 5): 0 selects 模型网关, 1 selects 聊天频道.
int? desktopAppModelsPane(DesktopAppId app) => switch (app) {
  DesktopAppId.modelsGateway => 0,
  DesktopAppId.modelsChatChannels => 1,
  _ => null,
};

/// The app occupying a models destination, mirrored from
/// [desktopAppModelsPane] so the strip can highlight the visible one.
DesktopAppId desktopModelsAppForPane(int pane) => switch (pane) {
  1 => DesktopAppId.modelsChatChannels,
  _ => DesktopAppId.modelsGateway,
};

IconData desktopAppIcon(DesktopAppId app) => switch (app) {
  DesktopAppId.agentHub => Icons.auto_awesome_outlined,
  DesktopAppId.skillHub => Icons.library_books_outlined,
  DesktopAppId.pluginManagement => Icons.extension_outlined,
  DesktopAppId.monitoring => Icons.query_stats_outlined,
  DesktopAppId.modelsGateway => Icons.key_outlined,
  DesktopAppId.mobileRelay => Icons.qr_code_2_rounded,
  DesktopAppId.modelsChatChannels => Icons.forum_outlined,
};

String desktopAppLabel(LicoStrings strings, DesktopAppId app) => switch (app) {
  DesktopAppId.agentHub => strings.agentHub,
  DesktopAppId.skillHub => strings.skillsNav,
  DesktopAppId.pluginManagement => strings.pluginsNav,
  DesktopAppId.monitoring => strings.tokenUsage,
  DesktopAppId.modelsGateway => strings.modelGateway,
  DesktopAppId.mobileRelay => strings.mobilePairing,
  DesktopAppId.modelsChatChannels => strings.chatChannels,
};

/// Decodes a persisted app name. Unknown names and the retired 对话 entry
/// both decode to null so old dock layouts drop them silently.
DesktopAppId? desktopAppByName(String name) {
  for (final app in DesktopAppId.values) {
    if (app.name == name) return app;
  }
  return null;
}
