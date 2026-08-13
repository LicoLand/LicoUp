import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/components/messaging_search_capsule.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// The Messaging desktop window-chrome band over frosted glass: traffic-light
/// inset, the feature-owned conversation pill tabs, then the right cluster.
/// Agents hosts search in its conversation sidebar; destinations without that
/// sidebar retain the search control here.
final class MessagingChromeBand extends StatelessWidget {
  const MessagingChromeBand({
    super.key,
    required this.chrome,
    this.showSearch = true,
  });

  final LayoutChromePort chrome;
  final bool showSearch;

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
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth <
                MessagingDesktopMetrics.chromeSearchCollapseWidth;
            return Row(
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
                  if (compact)
                    _ChromeIconAction(
                      key: const Key('messaging-topstrip-search'),
                      tooltip: strings.sidebarSearchHint,
                      icon: Icons.search_rounded,
                      onPressed: () => chrome.openGlobalSearch(context),
                    )
                  else
                    MessagingSearchCapsule(
                      key: const Key('messaging-topstrip-search'),
                      width: MessagingDesktopMetrics.chromeSearchFieldWidth,
                      onTap: () => chrome.openGlobalSearch(context),
                    ),
                // Bell sits at the far-right chrome edge so the notification
                // panel (window top-right) reads as anchored to that corner.
                const SizedBox(width: 4),
                if (features != null) features.buildNotificationBell(context),
                const SizedBox(width: 10),
              ],
            );
          },
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
