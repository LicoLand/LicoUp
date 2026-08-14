import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// The Messaging desktop window-chrome band over frosted glass: traffic-light
/// inset, the feature-owned conversation pill tabs, then the right cluster
/// (search when needed, token usage, notifications).
final class MessagingChromeBand extends StatelessWidget {
  const MessagingChromeBand({
    super.key,
    required this.chrome,
    this.showSearch = true,
    required this.section,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final bool showSearch;
  final ClientSection section;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final features = LayoutChromeFeaturesScope.maybeOf(context);
    final dark = colors.isDark;
    return SizedBox(
      key: const Key('messaging-chrome-band'),
      height: MessagingDesktopMetrics.topBandExtent,
      // Light frosted tint only — blur is supplied by the native
      // NSVisualEffectView under the transparent window base.
      child: ColoredBox(
        color: MessagingDesktopMetrics.surfaceGlassTint(isDark: dark),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Traffic-light clearance: the native window controls
            // overlay this zone, so the band keeps it empty.
            const SizedBox(
              width: MessagingDesktopMetrics.trafficLightInset,
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child:
                    features?.buildConversationTabs(context) ??
                    const SizedBox.shrink(),
              ),
            ),
            const SizedBox(width: 8),
            if (showSearch)
              _ChromeIconAction(
                key: const Key('messaging-topstrip-search'),
                tooltip: strings.sidebarSearchHint,
                icon: Icons.search_rounded,
                onPressed: () => chrome.openGlobalSearch(context),
              ),
            const SizedBox(width: 4),
            _ChromeUsageButton(
              selected: section == ClientSection.monitoring,
              tooltip: strings.tokenUsage,
              onPressed: () => onSelectSection(
                section == ClientSection.monitoring
                    ? ClientSection.agents
                    : ClientSection.monitoring,
              ),
            ),
            // Bell sits at the far-right chrome edge so the notification
            // panel (window top-right) reads as anchored to that corner.
            const SizedBox(width: 4),
            if (features != null) features.buildNotificationBell(context),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

final class _ChromeUsageButton extends StatelessWidget {
  const _ChromeUsageButton({
    required this.selected,
    required this.tooltip,
    required this.onPressed,
  });

  final bool selected;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final iconColor = selected
        ? colors.textOnPrimary
        : MessagingDesktopMetrics.chromeIconMuted();
    return Semantics(
      button: true,
      selected: selected,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        waitDuration: LicoMotion.tooltipWait,
        child: InkWell(
          key: const Key('messaging-chrome-usage-button'),
          onTap: onPressed,
          customBorder: const CircleBorder(),
          hoverColor: MessagingDesktopMetrics.chromeControlHover(
            isDark: colors.isDark,
          ),
          child: AnimatedContainer(
            duration: LicoMotion.micro,
            curve: LicoMotion.standard,
            width: MessagingDesktopMetrics.chromeActionButtonExtent,
            height: MessagingDesktopMetrics.chromeActionButtonExtent,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected ? colors.primary : Colors.transparent,
            ),
            child: Icon(
              Icons.query_stats_outlined,
              size: 18,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChromeIconAction extends StatelessWidget {
  const _ChromeIconAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Tooltip(
      message: tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        hoverColor: MessagingDesktopMetrics.chromeControlHover(
          isDark: colors.isDark,
        ),
        child: SizedBox.square(
          dimension: MessagingDesktopMetrics.chromeActionButtonExtent,
          child: Icon(
            icon,
            size: 18,
            color: MessagingDesktopMetrics.chromeIconMuted(),
          ),
        ),
      ),
    );
  }
}
