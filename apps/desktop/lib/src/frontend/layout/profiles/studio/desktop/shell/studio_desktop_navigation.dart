import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

List<(ClientSection, String)> studioDesktopNavigationItems(
  LicoStrings strings,
) => <(ClientSection, String)>[(ClientSection.agents, strings.agents)];

String studioDesktopSectionTitle(LicoStrings strings, ClientSection section) =>
    switch (section) {
      ClientSection.agents => strings.agents,
      ClientSection.monitoring => strings.tokenUsage,
      ClientSection.skillHub => strings.skillHub,
      ClientSection.mobileRelay => strings.mobileRelay,
      ClientSection.settings => strings.settings,
    };

IconData studioDesktopSectionIcon(ClientSection section) => switch (section) {
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.settings_outlined,
};

List<String> studioDesktopSectionSearchAliases(ClientSection section) =>
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
      ClientSection.mobileRelay => const <String>[
        'mobile',
        'relay',
        'pair',
        '配对',
      ],
      ClientSection.settings => const <String>['setting', 'preference', '设置'],
    };
