import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_component_kit.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

const LayoutComponentKit messagingDesktopComponentKit =
    MessagingDesktopComponentKit();

/// Messaging-owned control recipes: quiet tonal fills, moderate radii, and
/// the brand accent reserved for state — the channel-chat counterpart of the
/// Native kit.
final class MessagingDesktopComponentKit implements LayoutComponentKit {
  const MessagingDesktopComponentKit();

  @override
  String get styleIdentity => 'messaging-channel-chat';

  @override
  Widget navigationItem(
    BuildContext context, {
    required Key key,
    required Widget icon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final colors = context.layoutPalette;
    final tokens = context.layoutVisualTokens;
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reducedMotion ? Duration.zero : tokens.motionDuration;

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 500),
        child: Material(
          key: key,
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            mouseCursor: SystemMouseCursors.click,
            borderRadius: BorderRadius.circular(10),
            focusColor: colors.primary.withValues(alpha: 0.10),
            hoverColor: colors.text.withValues(alpha: 0.04),
            highlightColor: colors.primary.withValues(alpha: 0.08),
            child: AnimatedContainer(
              duration: duration,
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(minHeight: 32),
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary.withValues(
                        alpha: colors.isDark ? 0.14 : 0.10,
                      )
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              padding: EdgeInsetsDirectional.only(
                start: tokens.spacingUnit * 1.5,
                end: tokens.spacingUnit,
              ),
              child: Row(
                children: [
                  IconTheme(
                    data: IconThemeData(
                      size: 17,
                      color: selected ? colors.accent : colors.textMuted,
                    ),
                    child: icon,
                  ),
                  SizedBox(width: tokens.spacingUnit * 1.25),
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: selected ? colors.text : colors.textMuted,
                        fontSize: 12 * tokens.typographyScale,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        letterSpacing: 0.05,
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

  @override
  Widget panel(
    BuildContext context, {
    required Key key,
    required Widget child,
    bool emphasized = false,
  }) {
    final colors = context.layoutPalette;
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: emphasized ? colors.surfaceRaised : colors.surface,
        border: Border.all(color: colors.line.withAlpha(90)),
      ),
      child: child,
    );
  }

  @override
  Widget card(
    BuildContext context, {
    required Key key,
    required Widget child,
    VoidCallback? onPressed,
  }) {
    final colors = context.layoutPalette;
    final tokens = context.layoutVisualTokens;
    final body = Padding(
      padding: EdgeInsets.all(tokens.spacingUnit * 1.5),
      child: child,
    );
    return Material(
      key: key,
      color: colors.surfaceLow,
      elevation: tokens.elevation,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(tokens.cardRadius),
        side: BorderSide(color: colors.line.withAlpha(110)),
      ),
      clipBehavior: Clip.antiAlias,
      child: onPressed == null
          ? body
          : InkWell(
              onTap: onPressed,
              mouseCursor: SystemMouseCursors.click,
              child: body,
            ),
    );
  }

  @override
  Widget fieldFrame(
    BuildContext context, {
    required Key key,
    required Widget child,
    String? semanticLabel,
  }) {
    final colors = context.layoutPalette;
    final tokens = context.layoutVisualTokens;
    return Semantics(
      label: semanticLabel,
      textField: semanticLabel != null,
      child: Container(
        key: key,
        constraints: BoxConstraints(
          minHeight: math.max(
            32,
            32 * MediaQuery.textScalerOf(context).scale(1),
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacingUnit * 1.25,
          vertical: tokens.spacingUnit * 0.5,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          border: Border.all(color: colors.line.withAlpha(110)),
          borderRadius: BorderRadius.circular(tokens.cardRadius),
        ),
        child: child,
      ),
    );
  }

  @override
  Widget dialogSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    final colors = context.layoutPalette;
    final tokens = context.layoutVisualTokens;
    return ConstrainedBox(
      key: key,
      constraints: const BoxConstraints(maxWidth: 720),
      child: Material(
        color: colors.surface,
        elevation: tokens.elevation,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.cardRadius + 2),
          side: BorderSide(color: colors.line.withAlpha(130)),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }

  @override
  Widget statusSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
    required bool attention,
  }) {
    final colors = context.layoutPalette;
    final tokens = context.layoutVisualTokens;
    final accent = attention ? colors.warning : colors.accent;
    return Container(
      key: key,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacingUnit * 1.5,
        vertical: tokens.spacingUnit,
      ),
      decoration: BoxDecoration(
        color: attention ? colors.brandSurface : colors.surfaceLow,
        border: Border(
          left: BorderSide(color: accent, width: 2),
          top: BorderSide(color: colors.line.withAlpha(90)),
          right: BorderSide(color: colors.line.withAlpha(90)),
          bottom: BorderSide(color: colors.line.withAlpha(90)),
        ),
      ),
      child: child,
    );
  }
}
