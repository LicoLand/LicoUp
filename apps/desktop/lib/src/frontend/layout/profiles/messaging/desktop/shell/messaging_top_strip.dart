import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// The Messaging desktop window-chrome band over frosted glass: traffic-light
/// inset, the feature-owned conversation pill tabs, then the right cluster of
/// notification bell and the stadium search field at the far right.
final class MessagingChromeBand extends StatelessWidget {
  const MessagingChromeBand({super.key, required this.chrome});

  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final features = LayoutChromeFeaturesScope.maybeOf(context);
    final dark = colors.isDark;
    return Container(
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
                if (compact)
                  _ChromeIconAction(
                    key: const Key('messaging-topstrip-search'),
                    tooltip: strings.sidebarSearchHint,
                    icon: Icons.search_rounded,
                    onPressed: () => chrome.openGlobalSearch(context),
                  )
                else
                  _ChromeSearchField(chrome: chrome),
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

class _ChromeSearchField extends StatelessWidget {
  const _ChromeSearchField({required this.chrome});

  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return SizedBox(
      key: const Key('messaging-topstrip-search'),
      width: MessagingDesktopMetrics.chromeSearchFieldWidth,
      height: MessagingDesktopMetrics.searchFieldHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(
            MessagingDesktopMetrics.searchFieldCornerRadius,
          ),
          onTap: () => chrome.openGlobalSearch(context),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: MessagingDesktopMetrics.chromeControlFill(
                isDark: colors.isDark,
              ),
              borderRadius: BorderRadius.circular(
                MessagingDesktopMetrics.searchFieldCornerRadius,
              ),
              border: Border.all(
                color: MessagingDesktopMetrics.chromeSearchBorder(),
                width: MessagingDesktopMetrics.hairline,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.search_rounded,
                    size: 15,
                    color: MessagingDesktopMetrics.chromeSearchIcon(),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      strings.sidebarSearchHint,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color:
                            MessagingDesktopMetrics.chromeSearchPlaceholder(),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w400,
                        height: 1.0,
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
      waitDuration: const Duration(milliseconds: 400),
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
