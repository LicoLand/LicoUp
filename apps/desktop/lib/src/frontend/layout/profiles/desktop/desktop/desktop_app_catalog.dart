import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Every app the Desktop shell can host. The seven feature apps float above
/// the main area; 对话 is a fullscreen-exclusive app. 设置 and the 功能 app
/// store are pinned dock affordances, not catalog apps.
enum DesktopAppId {
  conversation,
  agentHub,
  skillHub,
  pluginManagement,
  monitoring,
  modelsGateway,
  mobileRelay,
  modelsChatChannels,
}

/// The visible floating feature apps in frozen catalog order.
const List<DesktopAppId> desktopFloatingApps = <DesktopAppId>[
  DesktopAppId.agentHub,
  DesktopAppId.monitoring,
  DesktopAppId.modelsGateway,
  DesktopAppId.mobileRelay,
];

/// The Launchpad built-in catalog: the visible feature apps plus 对话.
const List<DesktopAppId> desktopLaunchpadBuiltinApps = <DesktopAppId>[
  ...desktopFloatingApps,
  DesktopAppId.conversation,
];

bool desktopAppIsFloating(DesktopAppId app) => app != DesktopAppId.conversation;

ClientSection desktopAppSection(DesktopAppId app) => switch (app) {
  DesktopAppId.conversation => ClientSection.agents,
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

IconData desktopAppIcon(DesktopAppId app) => switch (app) {
  DesktopAppId.conversation => Icons.chat_bubble_outline_rounded,
  DesktopAppId.agentHub => Icons.auto_awesome_outlined,
  DesktopAppId.skillHub => Icons.library_books_outlined,
  DesktopAppId.pluginManagement => Icons.extension_outlined,
  DesktopAppId.monitoring => Icons.query_stats_outlined,
  DesktopAppId.modelsGateway => Icons.key_outlined,
  DesktopAppId.mobileRelay => Icons.qr_code_2_rounded,
  DesktopAppId.modelsChatChannels => Icons.forum_outlined,
};

String desktopAppLabel(LicoStrings strings, DesktopAppId app) => switch (app) {
  DesktopAppId.conversation => strings.conversationListNav,
  DesktopAppId.agentHub => strings.agentHub,
  DesktopAppId.skillHub => strings.skillsNav,
  DesktopAppId.pluginManagement => strings.pluginsNav,
  DesktopAppId.monitoring => strings.tokenUsage,
  DesktopAppId.modelsGateway => strings.modelGateway,
  DesktopAppId.mobileRelay => strings.mobilePairing,
  DesktopAppId.modelsChatChannels => strings.chatChannels,
};

DesktopAppId? desktopAppByName(String name) {
  for (final app in desktopLaunchpadBuiltinApps) {
    if (app.name == name) return app;
  }
  return null;
}
