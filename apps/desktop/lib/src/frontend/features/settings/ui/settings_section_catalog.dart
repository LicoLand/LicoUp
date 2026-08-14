import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';

/// Canonical section order, also used to map the persisted tab index back to
/// a section identity.
const settingsSectionIdOrder = <String>[
  'general',
  'appearance',
  'updates',
  'startup',
  'catalog-convergence',
  'storage',
  'diagnostics',
  'archived-conversations',
];

/// One settings section's navigation identity, shared by the in-page index
/// rail and the dashboard folder sidebar's Settings sub-items.
typedef SettingsSectionDescriptor = ({String id, IconData icon, String label});

/// Localized navigation descriptors in canonical order. The scrollable
/// content for each section stays owned by the settings panel.
List<SettingsSectionDescriptor> settingsSectionDescriptors(
  LicoStrings strings,
) => [
  (id: 'general', icon: Icons.tune_outlined, label: strings.general),
  (id: 'appearance', icon: Icons.palette_outlined, label: strings.appearance),
  (
    id: 'updates',
    icon: Icons.system_update_alt,
    label: strings.isChinese ? '更新' : 'Updates',
  ),
  (
    id: 'startup',
    icon: Icons.rocket_launch_outlined,
    label: strings.isChinese ? '启动' : 'Startup',
  ),
  (
    id: 'catalog-convergence',
    icon: Icons.sync_alt_outlined,
    label: strings.isChinese ? '工具' : 'Tools',
  ),
  (
    id: 'storage',
    icon: Icons.inventory_2_outlined,
    label: strings.isChinese ? '存储' : 'Storage',
  ),
  (
    id: 'diagnostics',
    icon: Icons.bug_report_outlined,
    label: strings.diagnostics,
  ),
  (
    id: 'archived-conversations',
    icon: Icons.archive_outlined,
    label: strings.archivedConversations,
  ),
];
