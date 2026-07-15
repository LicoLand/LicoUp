import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

List<(ClientSection, String)> studioDesktopNavigationItems(
  LicoStrings strings,
) => <(ClientSection, String)>[
  (ClientSection.controlPanel, strings.controlPanel),
  (ClientSection.agents, strings.agents),
];

String studioDesktopSectionTitle(LicoStrings strings, ClientSection section) =>
    switch (section) {
      ClientSection.controlPanel => strings.controlPanel,
      ClientSection.agents => strings.agents,
      ClientSection.feed => strings.feed,
      ClientSection.monitoring => strings.tokenUsage,
      ClientSection.mcpPlugins => strings.extensionsHub,
      ClientSection.skillHub => strings.skillHub,
      ClientSection.localRuntime => strings.runtime,
      ClientSection.mobileRelay => strings.mobileRelay,
      ClientSection.settings => strings.settings,
    };

IconData studioDesktopSectionIcon(ClientSection section) => switch (section) {
  ClientSection.controlPanel => Icons.dashboard_outlined,
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.feed => Icons.dynamic_feed_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.mcpPlugins => Icons.extension_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.localRuntime => Icons.dns_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.settings_outlined,
};

List<String> studioDesktopSectionSearchAliases(ClientSection section) =>
    switch (section) {
      ClientSection.controlPanel => const <String>[
        'control',
        'panel',
        'dashboard',
        'home',
        'feed',
        'timeline',
        '控制面板',
        '动态',
        '主页',
        '广场',
      ],
      ClientSection.agents => const <String>['agent', 'chat', '智能体', '对话'],
      ClientSection.feed => const <String>['feed', 'timeline', '广场', '动态'],
      ClientSection.monitoring => const <String>[
        'token',
        'usage',
        'chart',
        'monitoring',
        '用量',
        '统计',
        '图表',
      ],
      ClientSection.mcpPlugins => const <String>[
        'mcp',
        'plugin',
        '插件',
        'skill',
        'hub',
        '技能',
        'extensions',
        '扩展',
      ],
      ClientSection.skillHub => const <String>['skill', 'hub', '技能'],
      ClientSection.localRuntime => const <String>['runtime', 'server', '运行时'],
      ClientSection.mobileRelay => const <String>[
        'mobile',
        'relay',
        'pair',
        '配对',
      ],
      ClientSection.settings => const <String>['setting', 'preference', '设置'],
    };
