import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_component_kit.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/tokens/bubble_desktop_tokens.dart';

final LayoutComponentKit bubbleDesktopComponentKit =
    const BubbleDesktopComponentKit();

/// Bubble-owned recipes. The straight edges and hairline separators keep
/// controls visually integrated with the dock instead of turning into cards.
final class BubbleDesktopComponentKit implements LayoutComponentKit {
  const BubbleDesktopComponentKit();

  @override
  String get styleIdentity => 'dense-docked-bubble';

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
            focusColor: colors.primary.withValues(alpha: 0.14),
            hoverColor: colors.primary.withValues(alpha: 0.08),
            highlightColor: colors.primary.withValues(alpha: 0.1),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showLabel =
                    constraints.maxWidth >=
                    BubbleDesktopMetrics.minimumLabeledRailExtent;
                return AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  constraints: const BoxConstraints(
                    minHeight: BubbleDesktopMetrics.navigationItemExtent,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? colors.primaryFixed : Colors.transparent,
                    border: Border(
                      left: BorderSide(
                        color: selected ? colors.primary : Colors.transparent,
                        width: selected ? 3 : 0,
                      ),
                    ),
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
                          size: 18,
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
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  letterSpacing: 0.1,
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
        border: Border.all(color: colors.line),
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
        side: BorderSide(color: colors.line),
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
            BubbleDesktopMetrics.fieldMinimumExtent,
            BubbleDesktopMetrics.fieldMinimumExtent *
                (MediaQuery.textScalerOf(context).scale(1)),
          ),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacingUnit * 1.25,
          vertical: tokens.spacingUnit * 0.5,
        ),
        decoration: BoxDecoration(
          color: colors.background,
          border: Border.all(color: colors.line),
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
        maxWidth: BubbleDesktopMetrics.dialogMaximumWidth,
      ),
      child: Material(
        color: colors.surface,
        elevation: tokens.elevation,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.cardRadius),
          side: BorderSide(color: colors.line, width: 1.5),
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
          left: BorderSide(color: accent, width: 3),
          top: BorderSide(color: colors.line),
          right: BorderSide(color: colors.line),
          bottom: BorderSide(color: colors.line),
        ),
      ),
      child: child,
    );
  }
}
