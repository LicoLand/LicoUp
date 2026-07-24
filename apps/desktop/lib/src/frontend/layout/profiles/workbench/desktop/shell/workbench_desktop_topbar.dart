import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/shell/workbench_desktop_navigation.dart';
import 'package:licoup/src/frontend/layout/profiles/workbench/desktop/shell/workbench_desktop_search.dart';

/// Workbench-private measurements required by the desktop shell and top bar.
abstract final class WorkbenchDesktopChromeMetrics {
  static const double searchButtonSize = 32;
  static const double searchButtonEdgeInset = 8;

  static double get searchButtonRadius => searchButtonSize / 2;

  static double get windowCornerRadius =>
      searchButtonRadius + searchButtonEdgeInset;

  static double get topBarHeight =>
      searchButtonSize + (searchButtonEdgeInset * 2);

  static BorderRadius get windowBorderRadius =>
      BorderRadius.circular(windowCornerRadius);
}

const double _trafficLightInset = 96;
const double _trailingInset = 10;
const double _trailingHitSize = 32;
const double _trailingIconSize = 22;

final class WorkbenchDesktopTopBar extends StatelessWidget {
  const WorkbenchDesktopTopBar({
    super.key,
    required this.chrome,
    required this.section,
    required this.onSearchSelect,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final ClientSection section;
  final ValueChanged<ClientSection> onSearchSelect;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;

    return SizedBox(
      height: WorkbenchDesktopChromeMetrics.topBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(bottom: BorderSide(color: colors.line.withAlpha(60))),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: WorkbenchDesktopSearch(
                  width: 240,
                  current: section,
                  onSelect: onSearchSelect,
                ),
              ),
            ),
            Positioned(
              left: isMacOS ? _trafficLightInset : 12,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerLeft,
                child: WorkbenchDesktopNavigation(
                  current: section,
                  onSelect: onSelectSection,
                ),
              ),
            ),
            Positioned(
              right: _trailingInset,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerRight,
                child: _WorkbenchTrailingTools(
                  chrome: chrome,
                  onSelectSection: onSelectSection,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _WorkbenchTrailingTools extends StatelessWidget {
  const _WorkbenchTrailingTools({
    required this.chrome,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final iconColor = colors.text.withAlpha(210);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WorkbenchTrailingIconButton(
          key: const Key('topbar-pairing-button'),
          tooltip: strings.mobileRelay,
          icon: Icons.qr_code_2_rounded,
          color: iconColor,
          onPressed: () => unawaited(chrome.openPairing(context)),
        ),
        const SizedBox(width: 2),
        _WorkbenchTrailingIconButton(
          key: const Key('topbar-settings-button'),
          tooltip: strings.settings,
          icon: Icons.settings_outlined,
          color: iconColor,
          onPressed: () => onSelectSection(ClientSection.settings),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            height: 16,
            child: VerticalDivider(
              key: const Key('topbar-trailing-divider'),
              width: 1,
              thickness: 1,
              color: colors.line.withAlpha(120),
            ),
          ),
        ),
        Tooltip(
          message: strings.settings,
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(
            key: const Key('topbar-avatar-button'),
            customBorder: const CircleBorder(),
            onTap: () => onSelectSection(ClientSection.settings),
            child: Container(
              width: _trailingHitSize,
              height: _trailingHitSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceLow,
                border: Border.all(color: colors.line.withAlpha(120)),
              ),
              child: Icon(
                Icons.person_rounded,
                size: _trailingIconSize,
                color: colors.textMuted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _WorkbenchTrailingIconButton extends StatelessWidget {
  const _WorkbenchTrailingIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox.square(
          dimension: _trailingHitSize,
          child: Icon(icon, size: _trailingIconSize, color: color),
        ),
      ),
    );
  }
}
