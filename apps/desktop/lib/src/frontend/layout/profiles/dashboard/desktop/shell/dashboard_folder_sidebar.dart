import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/settings_section_catalog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/shell/dashboard_desktop_search.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// Column one of the Dashboard's macOS-Notes composition: a flush folder
/// sidebar listing every semantic destination. The selected folder renders a
/// solid brand-yellow row with black text — the house selection rule — while
/// unselected rows stay plain with a subtle hover wash.
final class DashboardFolderSidebar extends StatelessWidget {
  const DashboardFolderSidebar({
    super.key,
    required this.section,
    required this.availableSections,
    required this.onSelectSection,
    required this.width,
    this.settingsSectionIndex = -1,
    this.onSelectSettingsSection,
  });

  final ClientSection section;
  final List<ClientSection> availableSections;
  final ValueChanged<ClientSection> onSelectSection;
  final double width;

  /// Active settings sub-item, driven by the settings panel's scroll-spy
  /// through the shared section tab channel. -1 means no selection.
  final int settingsSectionIndex;

  /// Selects a settings section; the settings panel scrolls to it.
  final ValueChanged<int>? onSelectSettingsSection;

  static const _sections = [
    ClientSection.agentHub,
    ClientSection.agents,
    ClientSection.skillHub,
    ClientSection.pluginManagement,
    ClientSection.mobileRelay,
    ClientSection.monitoring,
    ClientSection.models,
    ClientSection.settings,
  ];

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final settingsSubSections = settingsSectionDescriptors(strings);
    return Container(
      key: const Key('dashboard-folder-sidebar'),
      width: width,
      color: Colors.transparent,
      child: SafeArea(
        left: false,
        right: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Fixed traffic-light reservation: a rectangle owned solely by
            // the native window controls. The gap below it is a separate,
            // deliberately adjustable spacing to the search field.
            SizedBox(
              key: const Key(
                'dashboard-folder-sidebar-traffic-light-reservation',
              ),
              height: 28,
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DashboardDesktopSearch(
                width: width - 16,
                current: section,
                availableSections: availableSections,
                onSelect: onSelectSection,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final entry in _sections)
                    if (availableSections.contains(entry)) ...[
                      _DashboardFolderRow(
                        key: Key('dashboard-folder-nav-${entry.name}'),
                        section: entry,
                        label: _folderLabel(strings, entry),
                        icon: _folderIcon(entry),
                        selected: entry == section,
                        onPressed: () => onSelectSection(entry),
                      ),
                      // The Settings destination expands in place, Arc-style:
                      // its sections become sub-items while it is selected.
                      if (entry == ClientSection.settings &&
                          section == ClientSection.settings)
                        for (
                          var index = 0;
                          index < settingsSectionIdOrder.length;
                          index++
                        )
                          _DashboardFolderSubRow(
                            key: Key(
                              'dashboard-folder-nav-settings-${settingsSectionIdOrder[index]}',
                            ),
                            icon: settingsSubSections[index].icon,
                            label: settingsSubSections[index].label,
                            selected: settingsSectionIndex == index,
                            onPressed: () =>
                                onSelectSettingsSection?.call(index),
                          ),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _folderLabel(LicoStrings strings, ClientSection section) =>
      switch (section) {
        ClientSection.agents => strings.conversationListNav,
        ClientSection.skillHub => strings.skillsNav,
        ClientSection.pluginManagement => strings.pluginsNav,
        ClientSection.agentHub => strings.agentHub,
        ClientSection.mobileRelay => strings.mobileNav,
        ClientSection.monitoring => strings.statsNav,
        ClientSection.models => strings.keys,
        ClientSection.settings => strings.settings,
      };

  static IconData _folderIcon(ClientSection section) => switch (section) {
    ClientSection.agents => Icons.psychology_outlined,
    ClientSection.skillHub => Icons.library_books_outlined,
    ClientSection.pluginManagement => Icons.extension_outlined,
    ClientSection.agentHub => Icons.auto_awesome_outlined,
    ClientSection.mobileRelay => Icons.phonelink_outlined,
    ClientSection.monitoring => Icons.query_stats_outlined,
    ClientSection.models => Icons.key_outlined,
    ClientSection.settings => Icons.settings_outlined,
  };
}

/// Indented sub-item under the expanded Settings folder row: smaller, plain
/// gray selection (the parent row owns the brand-yellow highlight).
final class _DashboardFolderSubRow extends StatefulWidget {
  const _DashboardFolderSubRow({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_DashboardFolderSubRow> createState() => _DashboardFolderSubRowState();
}

final class _DashboardFolderSubRowState extends State<_DashboardFolderSubRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final foreground = selected || _hovered ? colors.text : colors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.only(left: 22, top: 2, bottom: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(7),
                color: selected
                    ? (colors.isDark
                          ? Colors.white.withAlpha(18)
                          : Colors.black.withAlpha(10))
                    : _hovered
                    ? (colors.isDark
                          ? Colors.white.withAlpha(10)
                          : Colors.black.withAlpha(6))
                    : Colors.transparent,
              ),
              child: Row(
                children: [
                  Icon(widget.icon, size: 14, color: foreground),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 12,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        letterSpacing: -0.08,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DashboardFolderRow extends StatefulWidget {
  const _DashboardFolderRow({
    super.key,
    required this.section,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final ClientSection section;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  State<_DashboardFolderRow> createState() => _DashboardFolderRowState();
}

final class _DashboardFolderRowState extends State<_DashboardFolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final foreground = selected
        ? colors.textOnPrimary
        : _hovered
        ? colors.text
        : colors.textMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.label,
      child: Tooltip(
        message: widget.label,
        waitDuration: LicoMotion.tooltipWait,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              margin: const EdgeInsets.symmetric(vertical: 5),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: selected
                    ? colors.primary
                    : _hovered
                    ? (colors.isDark
                          ? Colors.white.withAlpha(10)
                          : Colors.black.withAlpha(10))
                    : Colors.transparent,
              ),
              child: Row(
                children: [
                  Icon(widget.icon, size: 17, color: foreground),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        letterSpacing: -0.08,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
