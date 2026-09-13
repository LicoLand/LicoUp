import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_particle_field.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_effect.dart';

/// Compiled renderers. Persist only the id; constructing this catalog starts no
/// ticker, particle simulation, capture, or I/O.
const builtInLoadingEffects = <LicoLoadingEffect>[
  LicoLoadingEffect(
    id: 'spinner',
    englishLabel: 'Simple spinner (default)',
    chineseLabel: '简单转圈（默认）',
    indicatorBuilder: buildSimpleLoadingSpinner,
  ),
  LicoLoadingEffect(
    id: 'static',
    englishLabel: 'Static indicator',
    chineseLabel: '静态指示器',
    indicatorBuilder: buildSimpleLoadingSpinner,
    animated: false,
  ),
  LicoLoadingEffect(
    id: 'particles',
    englishLabel: 'Spinner with conversation particles',
    chineseLabel: '转圈与会话粒子效果',
    indicatorBuilder: buildSimpleLoadingSpinner,
    conversationBuilder: buildParticleConversationMotion,
  ),
];

LicoLoadingEffect loadingEffectForId(String id) =>
    builtInLoadingEffects.firstWhere(
      (effect) => effect.id == id,
      orElse: () => builtInLoadingEffects.first,
    );

Widget buildSimpleLoadingSpinner(
  BuildContext context,
  double size,
  double strokeWidth,
  Color? color,
) => CircularProgressIndicator(strokeWidth: strokeWidth, color: color);

Widget buildParticleConversationMotion(
  BuildContext context,
  ConversationMotionPresentation presentation,
) => ConversationParticleField(
  key: ValueKey(presentation.identity),
  assembled: presentation.assembled,
  anchors: ConversationMotionAnchors(
    content: Rect.fromCenter(
      center: presentation.anchors.content.center,
      width: presentation.anchors.content.shortestSide * 0.62,
      height: presentation.anchors.content.shortestSide * 0.62,
    ),
    avatar: presentation.anchors.avatar,
    composer: presentation.anchors.composer,
  ),
  avatarGlyph: presentation.glyph,
  onAssembled: presentation.onAssembled,
);
