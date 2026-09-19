import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_glass.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared clear-glass chrome for messaging conversation overlays: header
/// identity capsule, header icon buttons, and the floating composer field.
/// Fill / blur / shadow come from [MessagingDesktopMetrics] overlay tokens.
/// The rim is the glass owner's conic specular highlight, not a hairline.
class MessagingConversationOverlayGlass extends StatelessWidget {
  const MessagingConversationOverlayGlass({
    super.key,
    required this.child,
    required this.borderRadius,
    this.focused = false,
    this.readabilityVeil = false,
    this.veilFill,
    this.drawRim = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool focused;
  final bool drawRim;

  /// When true, layers a black readability veil under the shared overlay-glass
  /// wash. Defaults to
  /// [MessagingDesktopMetrics.conversationOverlayReadabilityVeilFill] unless
  /// [veilFill] is provided.
  final bool readabilityVeil;

  /// Optional override for the black readability veil (e.g. the stronger
  /// group-roster mask). Ignored when [readabilityVeil] is false.
  final Color? veilFill;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final isDark = colors.isDark;
    final washFill = MessagingDesktopMetrics.conversationOverlayGlassFill(
      isDark: isDark,
    );
    final content = readabilityVeil
        ? Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(child: ColoredBox(color: washFill)),
              Positioned.fill(
                child: DecoratedBox(
                  key: const Key(
                    'messaging-conversation-overlay-readability-veil',
                  ),
                  decoration: BoxDecoration(
                    color:
                        veilFill ??
                        MessagingDesktopMetrics.conversationOverlayReadabilityVeilFill(
                          isDark: isDark,
                        ),
                    borderRadius: borderRadius,
                  ),
                ),
              ),
              child,
            ],
          )
        : child;
    return LicoGlass(
      borderRadius: borderRadius,
      fill: readabilityVeil ? Colors.transparent : washFill,
      shadows: MessagingDesktopMetrics.conversationOverlayGlassShadows(
        isDark: isDark,
      ),
      size: LicoGlassSize.large,
      readBackdrop: true,
      blurSigma: MessagingDesktopMetrics.conversationOverlayGlassBlurSigma,
      drawRim: drawRim,
      trackLight: true,
      gelPress: false,
      focused: focused,
      focusColor: focused ? colors.accent : null,
      child: content,
    );
  }
}
