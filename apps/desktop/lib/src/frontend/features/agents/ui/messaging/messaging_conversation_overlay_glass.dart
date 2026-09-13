import 'dart:ui';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/glass_edge_light.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared clear-glass chrome for messaging conversation overlays: header
/// identity capsule, header icon buttons, and the floating composer field.
/// Fill / border / blur / shadow all come from [MessagingDesktopMetrics]
/// conversation-overlay tokens — do not hardcode per widget. A static
/// [GlassEdgeLight] paints a uniform specular rim around each capsule.
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
    final sigma = MessagingDesktopMetrics.conversationOverlayGlassBlurSigma;
    final border = focused
        ? colors.accent
        : MessagingDesktopMetrics.glassEdgeRimColor(isDark: colors.isDark);
    final isDark = colors.isDark;
    final washFill = MessagingDesktopMetrics.conversationOverlayGlassFill(
      isDark: isDark,
    );
    final decoration = BoxDecoration(
      color: readabilityVeil ? null : washFill,
      borderRadius: borderRadius,
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
        child: GlassEdgeLight(
          borderRadius: borderRadius,
          sheenExtent: 20,
          rimWidth: drawRim ? MessagingDesktopMetrics.hairline : 0,
          rimColor: border,
          child: DecoratedBox(decoration: decoration, child: content),
        ),
      ),
    );
  }
}
