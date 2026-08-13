import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// Shared search capsule for the Messaging desktop shell. The Agents page
/// hosts it at the top of the conversation list; other destinations retain it
/// in the chrome band.
final class MessagingSearchCapsule extends StatelessWidget {
  const MessagingSearchCapsule({super.key, required this.onTap, this.width});

  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.searchFieldCornerRadius,
    );
    return SizedBox(
      width: width,
      height: MessagingDesktopMetrics.searchFieldHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: MessagingDesktopMetrics.chromeControlFill(
                isDark: colors.isDark,
              ),
              borderRadius: radius,
              border: Border.all(
                color: MessagingDesktopMetrics.chromeSearchBorder(),
                width: MessagingDesktopMetrics.hairline,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
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
