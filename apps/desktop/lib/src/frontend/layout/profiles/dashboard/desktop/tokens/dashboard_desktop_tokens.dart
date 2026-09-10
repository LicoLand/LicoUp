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
