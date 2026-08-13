import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared frosted-glass chrome for messaging conversation overlays: header
/// identity capsule, header icon buttons, and the floating composer field.
/// Fill / border / blur / shadow all come from [MessagingDesktopMetrics]
/// conversation-overlay tokens — do not hardcode per widget.
class MessagingConversationOverlayGlass extends StatelessWidget {
  const MessagingConversationOverlayGlass({
    super.key,
    required this.child,
    required this.borderRadius,
    this.focused = false,
    this.readabilityVeil = false,
    this.veilFill,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool focused;

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
    final sigma = MessagingDesktopMetrics.conversationOverlayGlassBlurSigma;
    final border = focused
        ? colors.accent
        : MessagingDesktopMetrics.conversationOverlayGlassBorder(
            colors.line,
            isDark: colors.isDark,
          );
    final isDark = colors.isDark;
    final washFill = MessagingDesktopMetrics.conversationOverlayGlassFill(
      isDark: isDark,
    );
    final decoration = BoxDecoration(
      color: readabilityVeil ? null : washFill,
      borderRadius: borderRadius,
      border: Border.all(
        color: border,
        width: focused ? 1.5 : MessagingDesktopMetrics.hairline,
      ),
      boxShadow: MessagingDesktopMetrics.conversationOverlayGlassShadows(
        isDark: isDark,
      ),
    );
    final content = readabilityVeil
        ? Stack(
            fit: StackFit.passthrough,
            children: [
              Positioned.fill(child: ColoredBox(color: washFill)),
              // Black mask above the wash so the capsule reads as veiled glass.
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
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(decoration: decoration, child: content),
      ),
    );
  }
}
