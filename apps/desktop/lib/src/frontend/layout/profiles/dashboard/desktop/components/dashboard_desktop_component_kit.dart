import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_component_kit.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

/// Card-oriented component recipes owned exclusively by the desktop dashboard.
final class DashboardDesktopComponentKit implements LayoutComponentKit {
  const DashboardDesktopComponentKit();

  @override
  String get styleIdentity => 'spacious-card-dashboard';

  @override
  Widget navigationItem(
    BuildContext context, {
    required Key key,
    required Widget icon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final colors = Theme.of(context).colorScheme;
    final tokens = context.layoutVisualTokens;
    final foreground = selected
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;

    return Semantics(
      key: key,
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: selected ? colors.primaryContainer : colors.surfaceContainer,
          shape: StadiumBorder(
            side: BorderSide(
              color: selected
                  ? colors.primary.withValues(alpha: 0.34)
                  : colors.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: const StadiumBorder(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: tokens.navigationExtent.clamp(44, 64),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: tokens.spacingUnit * 1.75,
                  vertical: tokens.spacingUnit,
                ),
                child: ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconTheme(
                        data: IconThemeData(color: foreground, size: 20),
                        child: icon,
                      ),
                      SizedBox(width: tokens.spacingUnit),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: foreground,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ],
                  ),
                ),
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
    final colors = Theme.of(context).colorScheme;
    final tokens = context.layoutVisualTokens;
    final radius = BorderRadius.circular(
      emphasized ? tokens.cardRadius + 4 : tokens.cardRadius,
    );

    return Container(
      key: key,
      decoration: BoxDecoration(
        color: emphasized
            ? colors.surfaceContainerLowest
            : colors.surfaceContainerLow,
        borderRadius: radius,
        border: Border.all(
          color: colors.outlineVariant.withValues(
            alpha: emphasized ? 0.72 : 0.5,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: colors.shadow.withValues(alpha: emphasized ? 0.14 : 0.08),
            blurRadius: emphasized ? 34 : 20,
            spreadRadius: emphasized ? 1 : 0,
            offset: Offset(0, emphasized ? 12 : 7),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
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
    final colors = Theme.of(context).colorScheme;
    final tokens = context.layoutVisualTokens;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.cardRadius - 4),
      side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.54)),
    );
    final content = Padding(
      padding: EdgeInsets.all(tokens.spacingUnit * 2.5),
      child: child,
    );

    if (onPressed == null) {
      return Material(
        key: key,
        color: colors.surfaceContainer,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: content,
      );
    }

    return Semantics(
      key: key,
      button: true,
      child: Material(
        color: colors.surfaceContainer,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onPressed, child: content),
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
    final colors = Theme.of(context).colorScheme;
    final tokens = context.layoutVisualTokens;
    final framed = Container(
      constraints: const BoxConstraints(minHeight: 46),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(tokens.cardRadius - 8),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.62),
        ),
      ),
      child: child,
    );

    return Semantics(
      key: key,
      container: true,
      label: semanticLabel,
      explicitChildNodes: semanticLabel != null,
      child: framed,
    );
  }

  @override
  Widget dialogSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    final tokens = context.layoutVisualTokens;
    return Semantics(
      key: key,
      scopesRoute: true,
      explicitChildNodes: true,
      child: Material(
        color: colors.surfaceContainerLowest,
        elevation: tokens.elevation + 4,
        shadowColor: colors.shadow.withValues(alpha: 0.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.cardRadius + 6),
          side: BorderSide(
            color: colors.outlineVariant.withValues(alpha: 0.65),
          ),
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
    final colors = Theme.of(context).colorScheme;
    final tokens = context.layoutVisualTokens;
    return Semantics(
      key: key,
      container: true,
      liveRegion: attention,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: attention ? colors.tertiaryContainer : colors.surfaceContainer,
          borderRadius: BorderRadius.circular(tokens.cardRadius - 6),
          border: Border.all(
            color: attention
                ? colors.tertiary.withValues(alpha: 0.38)
                : colors.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacingUnit * 1.75,
            vertical: tokens.spacingUnit * 1.25,
          ),
          child: child,
        ),
      ),
    );
  }
}
