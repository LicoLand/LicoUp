import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// The Messaging desktop shell's unified outer content card: transparent glass
/// over native VE with a black readability veil, hairline border, soft
/// shadow, and shared corner radius. Sits inset from the content region's
/// trailing and bottom edges; top meets the chrome band and the leading edge
/// sits at the window's leading content edge.
///
/// Geometry and veil **must** come from [MessagingDesktopMetrics.mainContentCard*]
/// helpers — do not hardcode radius, alphas, or shadow values here.
final class MessagingMainContentCard extends StatelessWidget {
  const MessagingMainContentCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.only(
      left: MessagingDesktopMetrics.mainCardMargin,
      right: MessagingDesktopMetrics.mainCardMargin,
      bottom: MessagingDesktopMetrics.mainCardMargin,
    ),
  });

  final Widget child;

  /// Outer inset of the card within [MessagingContentRegion]. Defaults to the
  /// trailing and bottom [MessagingDesktopMetrics.mainCardMargin] gutter.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Padding(
      padding: padding,
      child: Container(
        key: const Key('messaging-desktop-main-card'),
        decoration: BoxDecoration(
          color: MessagingDesktopMetrics.mainContentCardFill(
            isDark: colors.isDark,
          ),
          borderRadius: BorderRadius.circular(
            MessagingDesktopMetrics.mainCardCornerRadius,
          ),
          border: Border.all(
            color: MessagingDesktopMetrics.mainContentCardBorder(
              colors.line,
              isDark: colors.isDark,
            ),
            width: MessagingDesktopMetrics.hairline,
          ),
          boxShadow: MessagingDesktopMetrics.mainContentCardShadows(
            isDark: colors.isDark,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
