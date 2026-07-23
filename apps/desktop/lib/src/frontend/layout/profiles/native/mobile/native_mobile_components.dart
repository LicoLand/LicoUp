import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_component_kit.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/native/mobile/native_mobile_tokens.dart';

const LayoutComponentKit nativeMobileComponents = NativeMobileComponentKit();

final class NativeMobileComponentKit implements LayoutComponentKit {
  const NativeMobileComponentKit();

  @override
  String get styleIdentity => nativeMobileStyleIdentity;

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
              NativeMobileMetrics.controlRadius,
            ),
            focusColor: colors.primary.withAlpha(42),
            hoverColor: colors.surfaceHighest.withAlpha(100),
            child: AnimatedContainer(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 110),
              curve: Curves.easeOutCubic,
              constraints: const BoxConstraints(
                minWidth: NativeMobileMetrics.touchTargetExtent,
                minHeight: NativeMobileMetrics.touchTargetExtent,
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
                    width: NativeMobileMetrics.hairline,
                  ),
                  right: BorderSide(
                    color: selected
                        ? colors.primary.withAlpha(80)
                        : Colors.transparent,
                    width: NativeMobileMetrics.hairline,
                  ),
                  bottom: BorderSide(
                    color: selected
                        ? colors.primary.withAlpha(80)
                        : Colors.transparent,
                    width: NativeMobileMetrics.hairline,
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
    final colors = context.layoutPalette;
    return DecoratedBox(
      key: key,
      decoration: BoxDecoration(
        color: emphasized ? colors.surfaceHigh : colors.surface,
        border: Border(
          left: BorderSide(
            color: emphasized ? colors.primary : colors.line,
            width: emphasized ? 3 : NativeMobileMetrics.hairline,
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
    final colors = context.layoutPalette;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NativeMobileMetrics.controlRadius),
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
    final colors = context.layoutPalette;
    return Semantics(
      key: key,
      container: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(
            NativeMobileMetrics.controlRadius,
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
    final colors = context.layoutPalette;
    return Material(
      key: key,
      color: colors.surface,
      elevation: 12,
      shadowColor: Colors.black.withAlpha(72),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(NativeMobileMetrics.compactRadius),
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
    final colors = context.layoutPalette;
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

IconData nativeMobileDestinationIcon(ClientSection destination) {
  return switch (destination) {
    ClientSection.agents => Icons.hub_outlined,
    ClientSection.mobileRelay => Icons.link_outlined,
    ClientSection.settings => Icons.tune_outlined,
    ClientSection.monitoring => Icons.monitor_heart_outlined,
    ClientSection.skillHub => Icons.extension_outlined,
    ClientSection.pluginManagement => Icons.extension_outlined,
  };
}
