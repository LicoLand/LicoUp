import 'package:flutter/painting.dart' show EdgeInsets;

import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

export 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart'
    show MessagingDesktopMetrics;

/// Geometry for the Dashboard desktop presentation: a transparent shell on
/// the clear window veil, one rounded main content card holding the
/// navigation sidebar (traffic lights at its top-left), and (in Agents) a
/// floating conversation-list card on a shared chat canvas.
final LayoutVisualTokens dashboardDesktopTokens = LayoutVisualTokens(
  spacingUnit: 6,
  density: 0.92,
  cardRadius: 10,
  elevation: 0,
  navigationExtent: 68,
  contentMaxWidth: 1600,
  typographyScale: 0.95,
  motionDuration: const Duration(milliseconds: 150),
);

/// Geometry of Dashboard's plain style: a slim navigation rail, a list
/// column and the flat detail surface side by side over the window's
/// translucent ground, separated by hairlines. The rail's top strip and the
/// list column's first row share
/// [MessagingDesktopMetrics.sidebarTopRowExtent] so both sit centred on the
/// native traffic-light cluster.
abstract final class DashboardPlainMetrics {
  static const double railExtent = 72;

  static const double railAvatarRing = 2;
  static const double railAvatarGap = 22;
  static const double railButtonExtent = 44;
  static const double railButtonRadius = 14;
  static const double railIconExtent = 22;
  static const double railButtonGap = 6;
  static const double railBottomInset = 14;
  static const double railBadgeExtent = 16;
  static const double railBadgeInset = 4;

  /// Default width of the list column before the user drags it.
  static const double listColumnExtent = 300;

  /// Horizontal/vertical insets of a single main view (22 vertical, 26
  /// horizontal like the reference design).
  static const EdgeInsets mainViewPadding = EdgeInsets.symmetric(
    horizontal: 26,
    vertical: 22,
  );

  static const double profileAvatarExtent = 72;
  static const double profileMaxWidth = 340;
}

/// The plain style's sidebar glass: on a translucent host the rail and the
