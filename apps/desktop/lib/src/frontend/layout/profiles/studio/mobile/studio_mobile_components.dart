import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/mobile/studio_mobile_tokens.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

const LayoutComponentKit studioMobileComponents = StudioMobileComponentKit();

final class StudioMobileComponentKit implements LayoutComponentKit {
  const StudioMobileComponentKit();

  @override
  String get styleIdentity => studioMobileStyleIdentity;

  @override
  Widget navigationItem(
    BuildContext context, {
    required Key key,
    required Widget icon,
    required String label,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    final colors = context.licoColors;
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Semantics(
      key: key,
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 450),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(
              StudioMobileMetrics.controlRadius,
            ),
            focusColor: colors.primary.withAlpha(42),
            hoverColor: colors.surfaceHighest.withAlpha(100),
            child: AnimatedContainer(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 110),
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(
                minWidth: StudioMobileMetrics.touchTargetExtent,
                minHeight: StudioMobileMetrics.touchTargetExtent,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary.withAlpha(colors.isDark ? 52 : 34)
                    : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: selected ? colors.primary : Colors.transparent,
                    width: selected ? 3 : 0,
                  ),
                  top: BorderSide(
                    color: selected
                        ? colors.primary.withAlpha(80)
                        : Colors.transparent,
                    width: StudioMobileMetrics.hairline,
                  ),
                  right: BorderSide(
                    color: selected
                        ? colors.primary.withAlpha(80)
                        : Colors.transparent,
                    width: StudioMobileMetrics.hairline,
                  ),
                  bottom: BorderSide(
                    color: selected
                        ? colors.primary.withAlpha(80)
                        : Colors.transparent,
                    width: StudioMobileMetrics.hairline,
                  ),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 96;
                  final text = Text(
                    label,
                    maxLines: compact ? 2 : 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: compact ? TextAlign.center : TextAlign.start,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: selected ? colors.primary : colors.textMuted,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      fontSize: compact ? 9 : 11,
                      height: 1.05,
                      letterSpacing: 0.15,
                    ),
                  );
                  if (compact) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconTheme(
                          data: IconThemeData(
                            size: 19,
                            color: selected ? colors.primary : colors.textMuted,
                          ),
                          child: icon,
                        ),
                        const SizedBox(height: 3),
                        Flexible(child: text),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      IconTheme(
                        data: IconThemeData(
                          size: 18,
                          color: selected ? colors.primary : colors.textMuted,
                        ),
                        child: icon,
                      ),
                      const SizedBox(width: 9),
                      Expanded(child: text),
                    ],
                  );
                },
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
    final colors = context.licoColors;
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: emphasized ? colors.surfaceHigh : colors.surface,
        border: Border(
          left: BorderSide(
            color: emphasized ? colors.primary : colors.line,
            width: emphasized ? 3 : StudioMobileMetrics.hairline,
          ),
          top: BorderSide(color: colors.line, width: 1),
          right: BorderSide(color: colors.line, width: 1),
          bottom: BorderSide(color: colors.line, width: 1),
        ),
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
    final colors = context.licoColors;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(StudioMobileMetrics.controlRadius),
      side: BorderSide(color: colors.line, width: 1),
    );
    return Material(
      key: key,
      color: colors.surfaceLow,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: onPressed == null
          ? child
          : Semantics(
              button: true,
              child: InkWell(
                onTap: onPressed,
                focusColor: colors.primary.withAlpha(36),
                hoverColor: colors.surfaceHighest.withAlpha(80),
                child: child,
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
    final colors = context.licoColors;
    return Semantics(
      key: key,
      container: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(
            StudioMobileMetrics.controlRadius,
          ),
          border: Border.all(color: colors.line, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: child,
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
    final colors = context.licoColors;
    return Material(
      key: key,
      color: colors.surface,
      elevation: 12,
      shadowColor: Colors.black.withAlpha(72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(StudioMobileMetrics.compactRadius),
        side: BorderSide(color: colors.line, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  @override
  Widget statusSurface(
    BuildContext context, {
    required Key key,
    required Widget child,
    required bool attention,
  }) {
    final colors = context.licoColors;
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: attention
            ? colors.warning.withAlpha(colors.isDark ? 34 : 22)
            : colors.surfaceLow,
        border: Border(
          left: BorderSide(
            color: attention ? colors.warning : colors.info,
            width: 3,
          ),
          bottom: BorderSide(color: colors.line, width: 1),
        ),
      ),
      child: child,
    );
  }
}

IconData studioMobileDestinationIcon(ClientSection destination) {
  return switch (destination) {
    ClientSection.agents => Icons.hub_outlined,
    ClientSection.feed => Icons.dynamic_feed_outlined,
    ClientSection.mobileRelay => Icons.link_outlined,
    ClientSection.settings => Icons.tune_outlined,
    ClientSection.controlPanel => Icons.space_dashboard_outlined,
    ClientSection.monitoring => Icons.monitor_heart_outlined,
    ClientSection.mcpPlugins ||
    ClientSection.skillHub => Icons.extension_outlined,
    ClientSection.localRuntime => Icons.memory_outlined,
  };
}
