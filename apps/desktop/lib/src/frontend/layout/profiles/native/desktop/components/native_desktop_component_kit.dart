import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_component_kit.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/native/desktop/tokens/native_desktop_tokens.dart';

final LayoutComponentKit nativeDesktopComponentKit =
    const NativeDesktopComponentKit();

/// Native-owned recipes. Soft radii, whisper-quiet fills, and one restrained
/// brand accent keep controls composed instead of loud.
final class NativeDesktopComponentKit implements LayoutComponentKit {
  const NativeDesktopComponentKit();

  @override
  String get styleIdentity => 'glassy-rail-native';

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
            borderRadius: BorderRadius.circular(7),
            focusColor: colors.primary.withValues(alpha: 0.10),
            hoverColor: colors.text.withValues(alpha: 0.04),
            highlightColor: colors.primary.withValues(alpha: 0.08),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showLabel =
                    constraints.maxWidth >=
                    NativeDesktopMetrics.minimumLabeledRailExtent;
                return AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  constraints: const BoxConstraints(
                    minHeight: NativeDesktopMetrics.navigationItemExtent,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? colors.primary.withValues(
                            alpha: colors.isDark ? 0.10 : 0.08,
                          )
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  padding: EdgeInsetsDirectional.only(
                    start: showLabel ? tokens.spacingUnit * 1.5 : 0,
                    end: showLabel ? tokens.spacingUnit : 0,
                  ),
                  child: Row(
                    mainAxisAlignment: showLabel
                        ? MainAxisAlignment.start
                        : MainAxisAlignment.center,
                    children: [
                      IconTheme(
                        data: IconThemeData(
                          size: 17,
                          color: selected
                              ? colors.primaryStrong
                              : colors.textMuted,
                        ),
                        child: icon,
                      ),
                      if (showLabel) ...[
                        SizedBox(width: tokens.spacingUnit * 1.25),
                        Expanded(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: selected
                                      ? colors.text
                                      : colors.textMuted,
                                  fontSize: 12 * tokens.typographyScale,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  letterSpacing: 0.05,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
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
        color: emphasized ? colors.surfaceHigh : colors.surface,
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
            NativeDesktopMetrics.fieldMinimumExtent,
            NativeDesktopMetrics.fieldMinimumExtent *
                (MediaQuery.textScalerOf(context).scale(1)),
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
      constraints: const BoxConstraints(
        maxWidth: NativeDesktopMetrics.dialogMaximumWidth,
      ),
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
    final accent = attention ? colors.warning : colors.info;
    return Container(
      key: key,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacingUnit * 1.5,
        vertical: tokens.spacingUnit,
      ),
      decoration: BoxDecoration(
        color: attention ? colors.surfaceHigh : colors.surfaceLow,
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
