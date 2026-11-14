import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_header_directive_controls.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_ground.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Default height of the flat conversation header; presentations may
/// declare `conversationHeaderBarExtent` (Desktop: 52).
const double messagingConversationHeaderBarExtent = 60;

/// The active presentation's bar extent.
double messagingConversationHeaderExtentOf(BuildContext context) =>
    maybeLayoutAgentsPresentationOf(context)?.conversationHeaderBarExtent ??
    messagingConversationHeaderBarExtent;

/// Avatar diameter inside the flat conversation header: extent − 24
/// (28 in a 52 bar, 36 in a 60 bar).
double messagingConversationHeaderBarAvatarExtentOf(BuildContext context) =>
    messagingConversationHeaderExtentOf(context) - 24;

/// Glyph size for a mark drawn inside the header avatar.
const double messagingConversationHeaderBarAvatarMarkExtent = 20;

/// Whether the active profile draws the desktop conversation header as a flat
/// bar instead of floating capsules.
bool messagingConversationHeaderUsesBar(BuildContext context) =>
    !isMobileClientPlatform(context) &&
    maybeLayoutAgentsPresentationOf(context)?.conversationHeaderStyle ==
        LayoutConversationHeaderStyle.bar;

/// Flat full-width conversation header: identity on the left, actions on the
/// right and a hairline along the bottom edge. The fill is translucent so the
/// transcript stays faintly visible as it scrolls beneath.
final class MessagingConversationHeaderBar extends StatelessWidget {
  const MessagingConversationHeaderBar({
    super.key,
    required this.avatar,
    required this.title,
    this.subtitle = '',
    this.switcherTriggerKey,
    this.actions = const <Widget>[],
  });

  final Widget avatar;
  final String title;
  final String subtitle;

  /// When set, the identity acts as the switcher trigger; when null the
  /// identity renders without the chevron affordance.
  final Key? switcherTriggerKey;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isDark = colors.isDark;
    final identity = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        avatar,
        const SizedBox(width: 12),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                key: const Key('messaging-conversation-header-bar-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: isDark ? 14 : 15,
                  height: 1.25,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle.isNotEmpty)
                Text(
                  subtitle,
                  key: const Key('messaging-conversation-header-bar-subtitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    const blur = MessagingDesktopMetrics.conversationOverlayGlassBlurSigma;
    // Spec §9: no live blur over the animated ambient layer — the bar takes
    // a near-opaque fill instead.
    final animates = LicoWindowGroundScope.animatesAmbientOf(context);
    final fill = isDark
        ? const Color(0xF7121217)
        : colors.surfaceSunken.withValues(alpha: animates ? 0.92 : 0.55);
    final body = CustomPaint(
      foregroundPainter: ContinuousEdgeHairlinePainter(
        color: isDark ? const Color(0x0FFFFFFF) : colors.line,
        edge: AxisDirection.down,
      ),
      child: ColoredBox(
        color: fill,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: switcherTriggerKey == null
                      ? identity
                      : MessagingHeaderSwitcherTrigger(
                          triggerKey: switcherTriggerKey!,
                          identity: identity,
                        ),
                ),
              ),
              if (actions.isNotEmpty) ...[const SizedBox(width: 8), ...actions],
              const MessagingHeaderCollapseControl(),
            ],
          ),
        ),
      ),
    );
    return SizedBox(
      key: const Key('messaging-conversation-header-bar'),
      width: double.infinity,
      height: messagingConversationHeaderExtentOf(context),
      child: animates
          ? body
          : ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: body,
              ),
            ),
    );
  }
}
