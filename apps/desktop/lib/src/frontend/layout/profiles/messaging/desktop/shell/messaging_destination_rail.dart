import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/shell/messaging_desktop_navigation.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// Far-left destination column on frosted glass: the page destinations
/// (agents, skill hub, plugin management, monitoring) and the pairing page
/// sit vertically centered as standalone rounded-rectangle buttons. A
/// selected destination renders a brand-yellow filled tile with a black
/// icon; unselected stays a plain muted icon with subtle hover. Avatar and
/// settings live outside the rail (band and profile page).
final class MessagingDestinationRail extends StatelessWidget {
  const MessagingDestinationRail({
    super.key,
    required this.section,
    required this.onSelectSection,
    required this.onToggleProfile,
    required this.profileOpen,
  });

  final ClientSection section;
  final ValueChanged<ClientSection> onSelectSection;
  final VoidCallback onToggleProfile;
  final bool profileOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final items = messagingDesktopNavigationItems(strings);
    final dark = colors.isDark;
    return Container(
      key: const Key('messaging-destination-rail'),
      width: MessagingDesktopMetrics.navigationRailExtent,
      // Light frosted tint only — blur is supplied by the native
      // NSVisualEffectView under the transparent window base.
      child: ColoredBox(
        color: MessagingDesktopMetrics.surfaceGlassTint(isDark: dark),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < items.length; index++) ...[
                      if (index > 0) const SizedBox(height: 8),
                      MessagingRailToggleButton(
                        key: Key(
                          'messaging-rail-nav-${items[index].$1.name}',
                        ),
                        selected: !profileOpen && section == items[index].$1,
                        tooltip: items[index].$2,
                        icon: messagingDesktopSectionIcon(items[index].$1),
                        onPressed: () => onSelectSection(items[index].$1),
                      ),
                    ],
                    const SizedBox(height: 8),
                    MessagingRailToggleButton(
                      key: const Key('messaging-rail-pairing-button'),
                      selected:
                          !profileOpen && section == ClientSection.mobileRelay,
                      tooltip: strings.mobileRelay,
                      icon: Icons.qr_code_2_rounded,
                      onPressed: () =>
                          onSelectSection(ClientSection.mobileRelay),
                    ),
                  ],
                ),
              ),
            ),
            MessagingRailToggleButton(
              key: const Key('messaging-rail-avatar-button'),
              selected: profileOpen,
              tooltip: strings.localUser,
              icon: Icons.person_outline_rounded,
              onPressed: onToggleProfile,
            ),
            const SizedBox(height: 8),
            MessagingRailToggleButton(
              key: const Key('messaging-rail-settings-button'),
              // The profile page replaces the settings destination, so
              // the two are never active at the same time.
              selected: section == ClientSection.settings && !profileOpen,
              tooltip: strings.settings,
              icon: Icons.settings_outlined,
              onPressed: () => onSelectSection(ClientSection.settings),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// One rounded-rectangle rail button: selected renders a brand-yellow
/// filled tile with a black icon; unselected is a plain muted icon with a
/// subtle hover wash.
final class MessagingRailToggleButton extends StatefulWidget {
  const MessagingRailToggleButton({
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
  State<MessagingRailToggleButton> createState() =>
      _MessagingRailToggleButtonState();
}

final class _MessagingRailToggleButtonState
    extends State<MessagingRailToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final iconColor = selected
        ? colors.textOnPrimary
        : _hovered
        ? MessagingDesktopMetrics.chromeIconHover()
        : MessagingDesktopMetrics.chromeIconMuted();
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
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              width: MessagingDesktopMetrics.railToggleExtent,
              height: MessagingDesktopMetrics.railToggleExtent,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(
                  MessagingDesktopMetrics.railToggleRadius,
                ),
                color: selected
                    ? colors.primary
                    : _hovered
                    ? colors.hoverOverlay
                    : Colors.transparent,
                // The active destination is the shell's primary brand
                // landmark, so it emits light rather than merely filling.
                boxShadow: selected
                    ? [
                        BoxShadow(
                          color: colors.brandGlow,
                          blurRadius: 16,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: Icon(widget.icon, size: 19, color: iconColor),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
