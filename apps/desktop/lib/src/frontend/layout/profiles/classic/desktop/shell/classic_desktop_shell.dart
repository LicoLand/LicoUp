import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/layout/profiles/classic/desktop/shell/classic_desktop_status_bar.dart';

/// Classic-owned left sidebar, title bar, and status chrome.
Widget buildClassicDesktopMediumShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _ClassicResidualShell(data: data, compact: true);

Widget buildClassicDesktopExpandedShell(
  BuildContext context,
  LayoutShellBuildContext data,
) => _ClassicResidualShell(data: data, compact: false);

final class _ClassicResidualShell extends StatelessWidget {
  const _ClassicResidualShell({required this.data, required this.compact});

  final LayoutShellBuildContext data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (data.environment.surface != LayoutRuntimeSurface.desktop) {
      throw const FormatException('classic_desktop_surface_invalid');
    }
    final colors = context.layoutPalette;
    final railCompact = compact || data.environment.width < 900;

    return Semantics(
      key: ValueKey<String>(
        'classic-desktop-${compact ? 'medium' : 'expanded'}-shell',
      ),
      container: true,
      label: data.destinationLabel(data.activeDestination),
      child: Material(
        color: colors.background,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ClassicSidebar(data: data, compact: railCompact),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ClassicTitleBar(data: data),
                  Expanded(
                    child: Padding(
                      padding: data.activeDestination == ClientSection.agents
                          ? EdgeInsets.zero
                          : const EdgeInsets.all(20),
                      child: Semantics(
                        key: ValueKey<String>(
                          'classic-desktop-focus-${data.initialFocusTarget}',
                        ),
                        container: true,
                        explicitChildNodes: true,
                        child: data.destination,
                      ),
                    ),
                  ),
                  ClassicDesktopStatusBar(chrome: data.chrome),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _ClassicSidebar extends StatelessWidget {
  const _ClassicSidebar({required this.data, required this.compact});

  final LayoutShellBuildContext data;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final stringsLabel = data.destinationLabel;
    final preferred = <ClientSection>[
      ClientSection.agents,
      ClientSection.skillHub,
      ClientSection.pluginManagement,
      ClientSection.monitoring,
      ClientSection.mobileRelay,
      ClientSection.settings,
    ];
    final items = <ClientSection>[
      for (final section in preferred)
        if (data.availableDestinations.contains(section)) section,
      for (final section in data.availableDestinations)
        if (!preferred.contains(section)) section,
    ];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: compact ? 64 : 220,
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      padding: EdgeInsets.all(compact ? 8 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, compact ? 12 : 18),
            child: Text(
              compact ? 'A' : 'Arc',
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                color: colors.primary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final section in items)
                  _ClassicNavButton(
                    key: ValueKey<String>('classic-nav-${section.name}'),
                    selected: section == data.activeDestination,
                    icon: _classicSectionIcon(section),
                    label: stringsLabel(section),
                    compact: compact,
                    onPressed: () => data.onSelectDestination(section),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ClassicTitleBar extends StatelessWidget {
  const _ClassicTitleBar({required this.data});

  final LayoutShellBuildContext data;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Container(
      height: 64,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Text(
        data.destinationLabel(data.activeDestination),
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

final class _ClassicNavButton extends StatelessWidget {
  const _ClassicNavButton({
    super.key,
    required this.selected,
    required this.icon,
    required this.label,
    required this.compact,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final fg = selected ? colors.primary : colors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected ? colors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: 10,
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: fg),
                if (!compact) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _classicSectionIcon(ClientSection section) => switch (section) {
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.pluginManagement => Icons.extension_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.settings_outlined,
};
