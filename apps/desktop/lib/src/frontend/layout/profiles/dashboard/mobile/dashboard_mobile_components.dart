import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_component_kit.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/mobile/dashboard_mobile_tokens.dart';

/// The complete styled component recipe for the Dashboard mobile profile.
///
/// The class is stateless by design: domain state and profile-local state stay
/// in the parent ports and the profile-scoped state store respectively.
final class DashboardMobileComponentKit implements LayoutComponentKit {
  const DashboardMobileComponentKit();

  @override
  String get styleIdentity => dashboardMobileStyleIdentity;

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
    final textTheme = Theme.of(context).textTheme;
    final baseLabelStyle = textTheme.labelLarge;
    final labelStyle = baseLabelStyle?.copyWith(
      color: selected ? colors.onPrimaryContainer : colors.onSurfaceVariant,
      fontSize:
          (baseLabelStyle.fontSize ?? 14) *
          dashboardMobileTokens.typographyScale,
      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
    );
    final foreground = selected
        ? colors.onPrimaryContainer
        : colors.onSurfaceVariant;

    return Semantics(
      key: key,
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? colors.primaryContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            dashboardMobileTokens.cardRadius * 0.72,
          ),
          side: BorderSide(
            color: selected
                ? colors.primary.withValues(alpha: 0.24)
                : colors.outlineVariant.withValues(alpha: 0.55),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          mouseCursor: SystemMouseCursors.click,
          focusColor: colors.primary.withValues(alpha: 0.14),
          hoverColor: colors.primary.withValues(alpha: 0.08),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: dashboardMobileTokens.spacingUnit * 1.5,
                vertical: dashboardMobileTokens.spacingUnit,
              ),
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    IconTheme(
                      data: IconThemeData(color: foreground, size: 22),
                      child: icon,
                    ),
                    SizedBox(width: dashboardMobileTokens.spacingUnit),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                  ],
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
    return Material(
      key: key,
      color: emphasized
          ? colors.surfaceContainerLowest
          : colors.surfaceContainerLow,
      elevation: emphasized ? dashboardMobileTokens.elevation : 0,
      shadowColor: colors.shadow.withValues(alpha: 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dashboardMobileTokens.cardRadius),
        side: BorderSide(
          color: emphasized
              ? colors.primary.withValues(alpha: 0.22)
              : colors.outlineVariant.withValues(alpha: 0.62),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(dashboardMobileTokens.spacingUnit * 2),
        child: child,
      ),
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
    final content = Padding(
      padding: EdgeInsets.all(dashboardMobileTokens.spacingUnit * 1.75),
      child: child,
    );

    return Semantics(
      key: key,
      button: onPressed != null,
      child: Material(
        color: colors.surfaceContainer,
        elevation: dashboardMobileTokens.elevation,
        shadowColor: colors.shadow.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            dashboardMobileTokens.cardRadius * 0.84,
          ),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: onPressed == null
            ? content
            : InkWell(
                onTap: onPressed,
                mouseCursor: SystemMouseCursors.click,
                focusColor: colors.primary.withValues(alpha: 0.12),
                hoverColor: colors.primary.withValues(alpha: 0.06),
                child: content,
              ),
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
    return Semantics(
      key: key,
      container: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(
            dashboardMobileTokens.cardRadius * 0.64,
          ),
          border: Border.all(
            color: colors.outlineVariant.withValues(alpha: 0.72),
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dashboardMobileTokens.spacingUnit * 1.5,
              vertical: dashboardMobileTokens.spacingUnit,
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget dialogSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: key,
      color: colors.surfaceContainerHigh,
      elevation: dashboardMobileTokens.elevation * 3,
      shadowColor: colors.shadow.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(dashboardMobileTokens.cardRadius),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.64)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: EdgeInsets.all(dashboardMobileTokens.spacingUnit * 2.5),
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
    final background = attention
        ? colors.tertiaryContainer
        : colors.secondaryContainer;
    final foreground = attention
        ? colors.onTertiaryContainer
        : colors.onSecondaryContainer;
    return Semantics(
      key: key,
      liveRegion: attention,
      container: true,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
        child: IconTheme.merge(
          data: IconThemeData(color: foreground),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(
                dashboardMobileTokens.cardRadius * 0.64,
              ),
              border: Border.all(color: foreground.withValues(alpha: 0.2)),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: dashboardMobileTokens.spacingUnit * 1.5,
                vertical: dashboardMobileTokens.spacingUnit,
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
