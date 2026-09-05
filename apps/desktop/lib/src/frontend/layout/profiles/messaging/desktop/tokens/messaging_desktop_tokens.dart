import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

export 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart'
    show MessagingDesktopMetrics;

/// Geometry for the Messaging desktop presentation: a window-chrome top band
/// above a transparent shell on native frosted glass, a rounded main content
/// card, and (in Agents) a floating conversation-list card on a shared chat
/// canvas.
final LayoutVisualTokens messagingDesktopTokens = LayoutVisualTokens(
  spacingUnit: 6,
  density: 0.92,
  cardRadius: 10,
  elevation: 0,
  navigationExtent: 68,
  contentMaxWidth: 1600,
  typographyScale: 0.95,
  motionDuration: const Duration(milliseconds: 150),
);
