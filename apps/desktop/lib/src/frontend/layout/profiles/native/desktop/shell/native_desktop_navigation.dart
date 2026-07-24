import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

List<(ClientSection, String)> nativeDesktopNavigationItems(
  LicoStrings strings,
) => <(ClientSection, String)>[
  (ClientSection.agents, strings.agents),
  (ClientSection.skillHub, strings.skillHub),
  (ClientSection.pluginManagement, strings.pluginManagement),
  (ClientSection.monitoring, strings.tokenUsage),
];

String nativeDesktopSectionTitle(LicoStrings strings, ClientSection section) =>
    switch (section) {
      ClientSection.agents => strings.agents,
      ClientSection.monitoring => strings.tokenUsage,
      ClientSection.skillHub => strings.skillHub,
      ClientSection.pluginManagement => strings.pluginManagement,
      ClientSection.mobileRelay => strings.mobileRelay,
      ClientSection.settings => strings.settings,
    };

IconData nativeDesktopSectionIcon(ClientSection section) => switch (section) {
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.pluginManagement => Icons.extension_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.settings_outlined,
};

List<String> nativeDesktopSectionSearchAliases(ClientSection section) =>
    switch (section) {
      ClientSection.agents => const <String>['agent', 'chat', '智能体', '对话'],
      ClientSection.monitoring => const <String>[
        'token',
        'usage',
        'chart',
        'monitoring',
        '用量',
        '统计',
        '图表',
      ],
      ClientSection.skillHub => const <String>['skill', 'hub', '技能'],
      ClientSection.pluginManagement => const <String>[
        'plugin',
        'adapter',
        '插件',
        '适配器',
      ],
      ClientSection.mobileRelay => const <String>[
        'mobile',
        'relay',
        'pair',
        '配对',
      ],
      ClientSection.settings => const <String>['setting', 'preference', '设置'],
    };
