import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_desktop_navigation.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_glass.dart';

const double _tileExtent = 40;
const double _rowExtent = 48;

/// Icon navigation rail: plain glyphs resting directly on the window
/// background — no card, no seam. Together with the top band and the window
/// background it forms the shell's first layer; selection is a quiet tonal
/// tile with a gold glyph and a thin edge tick.
final class NativeIconRail extends StatelessWidget {
  const NativeIconRail({
    super.key,
    required this.chrome,
    required this.section,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final ClientSection section;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final items = nativeDesktopNavigationItems(strings);

    return SizedBox(
      width: NativeDesktopChromeMetrics.iconRailExtent,
      child: Column(
        children: [
          // Traffic-light clearance: the native window controls overlay this
          // zone, so the rail keeps it empty.
          const SizedBox(height: NativeDesktopChromeMetrics.topBarHeight),
          for (final item in items)
            NativeRailButton(
              key: Key('native-rail-nav-${item.$1.name}'),
              selected: section == item.$1,
              tooltip: item.$2,
              icon: nativeDesktopSectionIcon(item.$1),
              onPressed: () => onSelectSection(item.$1),
            ),
          const Spacer(),
          NativeRailButton(
            key: const Key('native-rail-pairing-button'),
            selected: false,
            tooltip: strings.mobileRelay,
            icon: Icons.qr_code_2_rounded,
            onPressed: () => unawaited(chrome.openPairing(context)),
          ),
          NativeRailButton(
            key: const Key('native-rail-settings-button'),
            selected: section == ClientSection.settings,
            tooltip: strings.settings,
            icon: Icons.settings_outlined,
            onPressed: () => onSelectSection(ClientSection.settings),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// One icon-rail entry: a 40×40 tonal tile centered in the rail, with an
/// animated gold edge tick while selected.
final class NativeRailButton extends StatefulWidget {
  const NativeRailButton({
    super.key,
    required this.selected,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final bool selected;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<NativeRailButton> createState() => _NativeRailButtonState();
}

final class _NativeRailButtonState extends State<NativeRailButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    return Semantics(
      button: true,
      selected: selected,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: SizedBox(
              width: double.infinity,
              height: _rowExtent,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    width: _tileExtent,
                    height: _tileExtent,
                    decoration: selected
                        ? NativeGlass.railSelection(colors)
                        : _hovered
                        ? NativeGlass.hoverPill(colors)
                        : const BoxDecoration(),
                    child: Center(
                      child: TweenAnimationBuilder<Color?>(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        tween: ColorTween(
                          end: selected
                              ? colors.primary
                              : _hovered
                              ? colors.text.withAlpha(230)
                              : colors.textMuted,
                        ),
                        builder: (context, color, _) =>
                            Icon(widget.icon, size: 20, color: color),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 6,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      opacity: selected ? 1 : 0,
                      child: Container(
                        width: 3,
                        height: 18,
                        decoration: BoxDecoration(
                          color: colors.primary,
                          borderRadius: BorderRadius.circular(1.5),
                          boxShadow: [
                            BoxShadow(
                              color: colors.primary.withAlpha(70),
                              blurRadius: 6,
                              spreadRadius: -1,
                            ),
                          ],
                        ),
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
