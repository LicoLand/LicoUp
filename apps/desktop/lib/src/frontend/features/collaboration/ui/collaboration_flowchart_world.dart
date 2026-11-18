import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_card_model.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_cards.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_paint.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_scene.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_style.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Transient effects that run when the plan or the work changes.
final class CollaborationWorldEffects {
  const CollaborationWorldEffects({
    required this.relayout,
    required this.entrance,
    required this.entering,
    required this.drawIn,
    required this.drawInKeys,
    required this.dispatch,
    required this.dispatchKeys,
  });

  /// 0..1 after the layout changed: routes fade back in and [entering] cards
  /// grow in while the rest glide to their new places.
  final Animation<double> relayout;

  /// [relayout] eased for the cards that enter.
  final Animation<double> entrance;
  final Set<String> entering;

  /// 0..1 after a revision applied: its added routes draw in.
  final Animation<double> drawIn;
  final Set<String> drawInKeys;

  /// 0..1 after work was handed off: one dot runs along each new active
  /// route.
  final Animation<double> dispatch;
  final Set<String> dispatchKeys;
}

/// The flowchart in world coordinates: phase headers, routes and cards.
final class CollaborationFlowchartWorld extends StatelessWidget {
  const CollaborationFlowchartWorld({
    super.key,
    required this.scene,
    required this.metrics,
    required this.animations,
    required this.effects,
    required this.hovered,
    required this.focusNodeFor,
    required this.onOpen,
    required this.onBackgroundTap,
  });

  final CollaborationFlowchartScene scene;
  final CollaborationCardMetrics metrics;
  final CollaborationCardAnimations animations;
  final CollaborationWorldEffects effects;
  final ValueNotifier<String?> hovered;
  final FocusNode Function(String displayId) focusNodeFor;
  final ValueChanged<String> onOpen;
  final VoidCallback onBackgroundTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final layout = scene.layout;
    final glide = context.motion(LicoMotion.long);
    return SizedBox.fromSize(
      size: layout.worldSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBackgroundTap,
            ),
          ),
          for (final phase in scene.phases)
            Positioned.fromRect(
              rect: phase.rect,
              child: _PhaseHeader(title: phase.title),
            ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: FadeTransition(
                  opacity: effects.relayout,
                  child: CustomPaint(
                    painter: CollaborationEdgePainter(
                      routes: scene.routes,
                      styles: scene.edgeStyles,
                      colors: colors,
                      showAdded: scene.plan.diff != null,
                      hovered: hovered,
                      flow: animations.spin,
                      animate: animations.enabled,
                      drawIn: effects.drawIn,
                      drawInKeys: effects.drawInKeys,
                      dispatch: effects.dispatch,
                      dispatchKeys: effects.dispatchKeys,
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final card in layout.cards)
            AnimatedPositioned(
              key: ValueKey(card.id),
              duration: glide,
              curve: LicoMotion.standard,
              left: card.rect.left,
              top: card.rect.top,
              width: card.rect.width,
              height: card.rect.height,
              child: KeyedSubtree(
                key: Key('collab-card-${card.id}'),
                child: RepaintBoundary(
                  child: CollaborationCardView(
                    model: scene.models[card.id]!,
                    metrics: metrics,
                    animations: animations,
                    focusNode: focusNodeFor(card.id),
                    entrance: effects.entering.contains(card.id)
                        ? effects.entrance
                        : null,
                    onOpen: switch (scene.models[card.id]!) {
                      CollaborationTaskCardModel() ||
                      CollaborationStackCardModel() => () => onOpen(card.id),
                      _ => null,
                    },
                    onHover: (inside) {
                      if (inside) {
                        hovered.value = card.id;
                      } else if (hovered.value == card.id) {
                        hovered.value = null;
                      }
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

final class _PhaseHeader extends StatelessWidget {
  const _PhaseHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.lineStrong, width: 1.5),
        ),
      ),
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: LicoTypography.eyebrow(color: colors.textMuted),
          ),
        ),
      ),
    );
  }
}
