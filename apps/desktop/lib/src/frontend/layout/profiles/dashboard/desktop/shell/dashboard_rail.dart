import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/dashboard/desktop/tokens/dashboard_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_self_avatar.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_sidebar_navigation.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_selection_highlight.dart';

/// One entry of the plain Dashboard navigation rail.
enum DashboardRailItem { messages, agents, features, settings }

/// Destinations the Features entry shows in the list column: every feature
/// pane except Agent Hub, which has its own rail entry.
bool dashboardRailFeatureColumnHosts(ClientSection section) =>
    section != ClientSection.agentHub && messagingSidebarHostsFeatures(section);

DashboardRailItem dashboardRailItemFor(ClientSection section) =>
    switch (section) {
      ClientSection.agents => DashboardRailItem.messages,
      ClientSection.agentHub => DashboardRailItem.agents,
      ClientSection.settings => DashboardRailItem.settings,
      _ => DashboardRailItem.features,
    };

/// The plain Dashboard navigation rail below the window's title band: the
/// local user's avatar (opens the profile page), Messages, Agents and
/// Features, and Settings at the bottom. The rail paints no fill — it sits
/// on the window ground, separated by its right hairline.
final class DashboardRail extends StatelessWidget {
  const DashboardRail({
    super.key,
    required this.selected,
    required this.selfMascotId,
    required this.onSelfMascotChanged,
    required this.onSelect,
  });

  /// The highlighted entry.
  final DashboardRailItem? selected;

  /// The mascot the local user picked in the self profile card this session;
  /// the rail avatar and the card share the selection.
  final String? selfMascotId;
  final ValueChanged<String> onSelfMascotChanged;
  final ValueChanged<DashboardRailItem> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final collaboration = LayoutChromeFeaturesScope.maybeOf(
      context,
    )?.collaborationApp;
    Widget button(DashboardRailItem item, {int badge = 0}) =>
        _DashboardRailButton(
          key: Key('dashboard-rail-${item.name}'),
          icon: _icon(item),
          label: _label(strings, item),
          selected: selected == item,
          badge: badge,
          onPressed: () => onSelect(item),
        );
    return CustomPaint(
      key: const Key('dashboard-rail'),
      foregroundPainter: ContinuousEdgeHairlinePainter(
        color: colors.line,
        edge: AxisDirection.right,
      ),
      child: SizedBox(
        width: DashboardPlainMetrics.railExtent,
        child: Column(
          children: [
            // One compact gap under the top strip: the avatar's footprint
            // (44x44 with its ring) matches the first content band's top
            // and height in the list column.
            const SizedBox(height: LicoContentSpacing.compact),
            _DashboardRailSelfButton(
              label: strings.viewMyProfile,
              mascotId: selfMascotId,
              onMascotChanged: onSelfMascotChanged,
              onOpenSettings: () => onSelect(DashboardRailItem.settings),
            ),
            const SizedBox(height: DashboardPlainMetrics.railAvatarGap),
            if (collaboration == null)
              button(DashboardRailItem.messages)
            else
              ValueListenableBuilder<LayoutCollaborationAppState>(
                valueListenable: collaboration,
                builder: (context, state, _) => button(
                  DashboardRailItem.messages,
                  badge: state.pendingDecisions,
                ),
              ),
            const SizedBox(height: DashboardPlainMetrics.railButtonGap),
            button(DashboardRailItem.agents),
            const SizedBox(height: DashboardPlainMetrics.railButtonGap),
            button(DashboardRailItem.features),
            const Spacer(),
            button(DashboardRailItem.settings),
            const SizedBox(height: DashboardPlainMetrics.railBottomInset),
          ],
        ),
      ),
    );
  }

  static IconData _icon(DashboardRailItem item) => switch (item) {
    DashboardRailItem.messages => messagingSidebarNavIcon(
      MessagingSidebarNavItem.conversations,
    ),
    DashboardRailItem.agents => messagingSidebarDestinationIcon(
      ClientSection.agentHub,
    ),
    DashboardRailItem.features => messagingSidebarNavIcon(
      MessagingSidebarNavItem.features,
    ),
    DashboardRailItem.settings => messagingSidebarNavIcon(
      MessagingSidebarNavItem.settings,
    ),
  };

  static String _label(LicoStrings strings, DashboardRailItem item) =>
      switch (item) {
        DashboardRailItem.messages => strings.messages,
        DashboardRailItem.agents => strings.agentHub,
        DashboardRailItem.features => strings.features,
        DashboardRailItem.settings => strings.settings,
      };
}

/// Shared pointer, keyboard and tooltip behaviour of the rail controls.
/// Paints the self avatar's hover ring entirely outside the avatar's
/// rect, so the stroke adds no footprint and crops no artwork.
final class _SelfAvatarRingPainter extends CustomPainter {
  const _SelfAvatarRingPainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    canvas.drawCircle(
      size.center(Offset.zero),
      size.width / 2 + width / 2,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = width,
    );
  }

  @override
  bool shouldRepaint(covariant _SelfAvatarRingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.width != width;
}

final class _DashboardRailPressable extends StatefulWidget {
  const _DashboardRailPressable({
    required this.label,
    required this.selected,
    required this.onPressed,
    required this.builder,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_DashboardRailPressable> createState() =>
      _DashboardRailPressableState();
}

final class _DashboardRailPressableState
    extends State<_DashboardRailPressable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.label,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        onTap: widget.onPressed,
        excludeSemantics: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: FocusableActionDetector(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed();
                  return null;
                },
              ),
            },
            onShowFocusHighlight: (focused) =>
                setState(() => _hovered = focused),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPressed,
              child: widget.builder(context, _hovered),
            ),
          ),
        ),
      ),
    );
  }
}

final class _DashboardRailButton extends StatelessWidget {
  const _DashboardRailButton({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.badge,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final int badge;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final starlight = LicoSelectionLight.isStarlight(context);
    return _DashboardRailPressable(
      label: label,
      selected: selected,
      onPressed: onPressed,
      builder: (context, hovered) {
        final foreground = selected
            ? colors.selectionInk
            : hovered
            ? colors.textSecondary
            : colors.textMuted;
        final button = AnimatedContainer(
          duration: context.motion(LicoMotion.micro),
          curve: LicoMotion.standard,
          width: DashboardPlainMetrics.railButtonExtent,
          height: DashboardPlainMetrics.railButtonExtent,
          decoration: BoxDecoration(
            color: hovered && !selected
                ? LicoSelectionLight.hoverFill(context)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(
              DashboardPlainMetrics.railButtonRadius,
            ),
          ),
          child: LicoSelectionLight(
            selected: selected && !starlight,
            radius: DashboardPlainMetrics.railButtonRadius,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // Starlight: the selected icon floats on a halo clipped
                // inside its own box — no fill or rim reaches the edge.
                if (selected && starlight)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          colors: [
                            colors.selectionInk.withValues(alpha: 0.18),
                            colors.selectionInk.withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                  ),
                Icon(
                  icon,
                  size: DashboardPlainMetrics.railIconExtent,
                  color: foreground,
                  shadows: selected && colors.isDark
                      ? [
                          Shadow(
                            color: colors.accentGlow,
                            blurRadius: starlight ? 10 : 8,
                          ),
                        ]
                      : null,
                ),
                if (badge > 0)
                  Positioned(
                    top: DashboardPlainMetrics.railBadgeInset,
                    right: DashboardPlainMetrics.railBadgeInset,
                    child: _DashboardRailBadge(count: badge),
                  ),
              ],
            ),
          ),
        );
        if (!starlight) {
          return button;
        }
        // Starlight's marker is a small light at the rail's window edge,
        // centred on the selected button, not a card behind the icon.
        return SizedBox(
          width: double.infinity,
          height: DashboardPlainMetrics.railButtonExtent,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: AnimatedOpacity(
                    duration: context.motion(LicoMotion.micro),
                    opacity: selected ? 1 : 0,
                    child: Container(
                      key: const Key('dashboard-rail-indicator'),
                      width: 3,
                      height: 20,
                      decoration: BoxDecoration(
                        color: colors.selectionInk,
                        borderRadius: const BorderRadius.horizontal(
                          right: Radius.circular(2),
                        ),
                        boxShadow: [
                          BoxShadow(color: colors.accentGlow, blurRadius: 5),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              button,
            ],
          ),
        );
      },
    );
  }
}

final class _DashboardRailBadge extends StatelessWidget {
  const _DashboardRailBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Container(
      key: const Key('dashboard-rail-badge'),
      constraints: const BoxConstraints(
        minWidth: DashboardPlainMetrics.railBadgeExtent,
        minHeight: DashboardPlainMetrics.railBadgeExtent,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.unreadBadgeFill,
        borderRadius: BorderRadius.circular(
          DashboardPlainMetrics.railBadgeExtent / 2,
        ),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// The local user's avatar. A ring marks it while the profile page is open.
final class _DashboardRailSelfButton extends StatelessWidget {
  const _DashboardRailSelfButton({
    required this.label,
    required this.mascotId,
    required this.onMascotChanged,
    required this.onOpenSettings,
  });

  final String label;
  final String? mascotId;
  final ValueChanged<String> onMascotChanged;
  final VoidCallback onOpenSettings;

  /// The rail avatar opens the local user's floating `.profile-card` to its
  /// right — the demo's `openProfile` on the self avatar — instead of
  /// swapping the workspace for a full profile page.
  void _openSelfCard(BuildContext anchorContext) {
    final features = LayoutChromeFeaturesScope.maybeOf(anchorContext);
    if (features == null) return;
    final box = anchorContext.findRenderObject();
    final anchorRect = box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    unawaited(
      features.openSelfProfile(
        anchorContext,
        anchorRect: anchorRect,
        mascotId: mascotId,
        onMascotChanged: onMascotChanged,
        onOpenSettings: onOpenSettings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final features = LayoutChromeFeaturesScope.maybeOf(context);
    return Builder(
      builder: (anchorContext) => _DashboardRailPressable(
        label: label,
        selected: false,
        onPressed: () => _openSelfCard(anchorContext),
        // The hover ring paints outside the 44 box, so the avatar's
        // visible footprint equals one rail button and the list column's
        // first content band — the ring never shrinks the artwork.
        builder: (context, hovered) => CustomPaint(
          key: const Key('dashboard-rail-self'),
          foregroundPainter: _SelfAvatarRingPainter(
            color: hovered ? colors.line : Colors.transparent,
            width: DashboardPlainMetrics.railAvatarRing,
          ),
          child: SizedBox.square(
            dimension: DashboardPlainMetrics.railButtonExtent,
            child:
                features?.buildSelfAvatar(
                  context,
                  size: DashboardPlainMetrics.railButtonExtent,
                  mascotId: mascotId,
                ) ??
                MessagingSelfAvatar(
                  size: DashboardPlainMetrics.railButtonExtent,
                  mascotId: mascotId,
                ),
          ),
        ),
      ),
    );
  }
}
