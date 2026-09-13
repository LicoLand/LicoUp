import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/messaging/conversation_motion/conversation_motion_geometry.dart';

typedef LicoLoadingIndicatorBuilder =
    Widget Function(
      BuildContext context,
      double size,
      double strokeWidth,
      Color? color,
    );

typedef ConversationMotionBuilder =
    Widget Function(
      BuildContext context,
      ConversationMotionPresentation presentation,
    );

/// A visual plug-in. Builders are invoked only for a mounted loading indicator
/// or an active conversation scene; data reads never depend on this contract.
class LicoLoadingEffect {
  const LicoLoadingEffect({
    required this.id,
    required this.englishLabel,
    required this.chineseLabel,
    required this.indicatorBuilder,
    this.conversationBuilder,
    this.animated = true,
  });

  final String id;
  final String englishLabel;
  final String chineseLabel;
  final LicoLoadingIndicatorBuilder indicatorBuilder;
  final ConversationMotionBuilder? conversationBuilder;
  final bool animated;
}

/// Replace this scope to load another renderer without replacing its content.
class LicoLoadingEffectScope extends InheritedWidget {
  const LicoLoadingEffectScope({
    super.key,
    required this.effect,
    required super.child,
  });

  final LicoLoadingEffect effect;

  static LicoLoadingEffect? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LicoLoadingEffectScope>()
      ?.effect;

  @override
  bool updateShouldNotify(LicoLoadingEffectScope oldWidget) =>
      oldWidget.effect != effect;
}

class ConversationMotionPresentation {
  const ConversationMotionPresentation({
    required this.identity,
    required this.assembled,
    required this.enabled,
    required this.anchors,
    required this.glyph,
    required this.onAssembled,
  });

  final Object identity;
  final bool assembled;
  final bool enabled;
  final ConversationMotionAnchors anchors;
  final ConversationMotionGlyph? glyph;
  final VoidCallback onAssembled;
}
