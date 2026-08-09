import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared frosted-glass floating card for messaging option lists and menus.
///
/// Use this as the default chrome for hover popovers, selectors, and
/// right-click context menus so they share one blur / border / radius recipe.
class MessagingGlassOptionCard extends StatelessWidget {
  const MessagingGlassOptionCard({
    super.key,
    required this.child,
    this.width,
    this.constraints,
    this.borderRadius,
    this.readabilityVeil = true,
    this.padding = const EdgeInsets.symmetric(vertical: 6),
  });

  final Widget child;
  final double? width;
  final BoxConstraints? constraints;
  final BorderRadius? borderRadius;
  final bool readabilityVeil;
  final EdgeInsetsGeometry padding;

  static BorderRadius get defaultBorderRadius =>
      BorderRadius.circular(AppleControlMetrics.menuCornerRadius);

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? defaultBorderRadius;
    return MessagingConversationOverlayGlass(
      borderRadius: radius,
      readabilityVeil: readabilityVeil,
      child: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: constraints ?? const BoxConstraints(),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// One tappable row inside a [MessagingGlassOptionCard].
class MessagingGlassMenuItem extends StatelessWidget {
  const MessagingGlassMenuItem({
    super.key,
    required this.label,
    this.leading,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.dense = false,
    this.enabled = true,
  });

  final String label;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final bool dense;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final height = dense ? 32.0 : 36.0;
    final horizontal = dense ? 10.0 : 12.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: height,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            child: Row(
              children: [
                if (leading != null) ...[
                  leading!,
                  SizedBox(width: dense ? 8 : 10),
                ],
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled
                          ? colors.text
                          : colors.textMuted.withAlpha(140),
                      fontSize: dense ? 12.5 : 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing!,
                ] else if (selected)
                  Icon(Icons.check_rounded, size: 15, color: colors.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Declarative action for [showMessagingGlassMenu].
@immutable
final class MessagingGlassMenuAction<T> {
  const MessagingGlassMenuAction({
    required this.value,
    required this.label,
    this.leading,
    this.enabled = true,
  });

  final T value;
  final String label;
  final Widget? leading;
  final bool enabled;
}

/// Show a glass floating context menu at [globalPosition], matching the
/// messaging selector / hover-card chrome (not Material [showMenu]).
Future<T?> showMessagingGlassMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<MessagingGlassMenuAction<T>> actions,
  double minWidth = 168,
  double maxWidth = 280,
  Key? menuKey,
}) {
  assert(actions.isNotEmpty, 'showMessagingGlassMenu requires actions');
  final navigator = Navigator.of(context, rootNavigator: false);
  return navigator.push<T>(
    _MessagingGlassMenuRoute<T>(
      globalPosition: globalPosition,
      actions: actions,
      minWidth: minWidth,
      maxWidth: maxWidth,
      menuKey: menuKey,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

final class _MessagingGlassMenuRoute<T> extends PopupRoute<T> {
  _MessagingGlassMenuRoute({
    required this.globalPosition,
    required this.actions,
    required this.minWidth,
    required this.maxWidth,
    required this.barrierLabel,
    this.menuKey,
  });

  final Offset globalPosition;
  final List<MessagingGlassMenuAction<T>> actions;
  final double minWidth;
  final double maxWidth;
  final Key? menuKey;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final size = media.size;
    final padding = media.padding;
    const estimatedRow = 36.0;
    final estimatedHeight =
        12.0 + actions.length * estimatedRow; // card padding + rows
    final left = globalPosition.dx
        .clamp(padding.left + 8, size.width - padding.right - minWidth - 8)
        .toDouble();
    var top = globalPosition.dy;
    if (top + estimatedHeight > size.height - padding.bottom - 8) {
      top = (globalPosition.dy - estimatedHeight).clamp(
        padding.top + 8,
        size.height - padding.bottom - estimatedHeight - 8,
      );
    }

    return CustomSingleChildLayout(
      delegate: _MessagingGlassMenuLayout(
        position: Offset(left, top),
        minWidth: minWidth,
        maxWidth: maxWidth,
        padding: padding,
        screenSize: size,
      ),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: Material(
          type: MaterialType.transparency,
          child: MessagingGlassOptionCard(
            key: menuKey ?? const Key('messaging-glass-context-menu'),
            width: minWidth,
            constraints: BoxConstraints(
              minWidth: minWidth,
              maxWidth: maxWidth,
              maxHeight: MessagingDesktopMetrics
                  .composerFlywheelSelectorPopoverMaxHeight,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final action in actions)
                  MessagingGlassMenuItem(
                    key: Key('messaging-glass-menu-${action.value}'),
                    label: action.label,
                    leading: action.leading,
                    enabled: action.enabled,
                    onTap: action.enabled
                        ? () => Navigator.of(context).pop(action.value)
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _MessagingGlassMenuLayout extends SingleChildLayoutDelegate {
  const _MessagingGlassMenuLayout({
    required this.position,
    required this.minWidth,
    required this.maxWidth,
    required this.padding,
    required this.screenSize,
  });

  final Offset position;
  final double minWidth;
  final double maxWidth;
  final EdgeInsets padding;
  final Size screenSize;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: minWidth,
      maxWidth: maxWidth,
      minHeight: 0,
      maxHeight: (screenSize.height - padding.vertical - 16).clamp(
        48.0,
        screenSize.height,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    var dx = position.dx;
    var dy = position.dy;
    if (dx + childSize.width > screenSize.width - padding.right - 8) {
      dx = screenSize.width - padding.right - 8 - childSize.width;
    }
    if (dy + childSize.height > screenSize.height - padding.bottom - 8) {
      dy = screenSize.height - padding.bottom - 8 - childSize.height;
    }
    dx = dx.clamp(padding.left + 8, screenSize.width);
    dy = dy.clamp(padding.top + 8, screenSize.height);
    return Offset(dx, dy);
  }

  @override
  bool shouldRelayout(covariant _MessagingGlassMenuLayout oldDelegate) {
    return position != oldDelegate.position ||
        minWidth != oldDelegate.minWidth ||
        maxWidth != oldDelegate.maxWidth ||
        padding != oldDelegate.padding ||
        screenSize != oldDelegate.screenSize;
  }
}
