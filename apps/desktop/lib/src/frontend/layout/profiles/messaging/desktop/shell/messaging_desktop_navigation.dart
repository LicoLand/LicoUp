import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// The Messaging desktop destination rail exposes the same semantic
/// destinations as the Native icon rail — the shared navigation model,
/// restyled as channel-chat tiles.
List<(ClientSection, String)> messagingDesktopNavigationItems(
  LicoStrings strings,
) => <(ClientSection, String)>[
  (ClientSection.agents, strings.agents),
  (ClientSection.skillHub, strings.skillHub),
  (ClientSection.pluginManagement, strings.pluginManagement),
  (ClientSection.monitoring, strings.tokenUsage),
  (ClientSection.models, strings.keys),
];

IconData messagingDesktopSectionIcon(ClientSection section) =>
    switch (section) {
      ClientSection.agents => Icons.psychology_outlined,
      ClientSection.monitoring => Icons.query_stats_outlined,
      ClientSection.skillHub => Icons.library_books_outlined,
      ClientSection.pluginManagement => Icons.extension_outlined,
      ClientSection.mobileRelay => Icons.phonelink_outlined,
      ClientSection.models => Icons.key_outlined,
      ClientSection.settings => Icons.settings_outlined,
    };
