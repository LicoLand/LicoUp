import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

/// The bundled Lico mascot pack — the same asset family the website ships
/// (`licoup.com/assets/lico`), embedded so the client can put a face on its
/// own moments: empty states, greetings, and identity slots.
///
/// Asset ids and bilingual names mirror `assets/mascot/manifest.json`.
abstract final class MascotCatalog {
  static const String _avatars = 'assets/mascot/avatars/png';
  static const String _expressions = 'assets/mascot/expressions/png';

  /// The twelve ice-cream avatar characters.
  static const Map<String, ({String en, String zh})> avatars = {
    'lico': (en: 'Lico', zh: 'Lico'),
    'berry': (en: 'Berry', zh: '莓莓'),
    'sprout': (en: 'Sprout', zh: '小芽'),
    'luna': (en: 'Luna', zh: '月月'),
    'cherry': (en: 'Cherry', zh: '樱桃'),
    'coco': (en: 'Coco', zh: '可可'),
    'melody': (en: 'Melody', zh: '旋律'),
    'scholar': (en: 'Scholar', zh: '学霸'),
    'blossom': (en: 'Blossom', zh: '花花'),
    'sunny': (en: 'Sunny', zh: '暖阳'),
    'orbit': (en: 'Orbit', zh: '星轨'),
    'mochi': (en: 'Mochi', zh: '糯米'),
  };

  /// The twenty-one expression faces of the Lico character.
  static const Map<String, ({String en, String zh})> expressions = {
    'neutral': (en: 'Smile', zh: '微笑'),
    'happy': (en: 'Happy', zh: '开心'),
    'laugh': (en: 'Laugh', zh: '大笑'),
    'hi': (en: 'Hi', zh: '打招呼'),
    'love': (en: 'Love', zh: '爱心'),
    'starstruck': (en: 'Starstruck', zh: '星星眼'),
    'wink': (en: 'Wink', zh: '眨眼'),
    'surprised': (en: 'Surprised', zh: '惊讶'),
    'thinking': (en: 'Thinking', zh: '思考'),
    'confused': (en: 'Confused', zh: '困惑'),
    'focused': (en: 'Focused', zh: '专注'),
    'speaking': (en: 'Speaking', zh: '说话中'),
    'listening': (en: 'Listening', zh: '倾听'),
    'approve': (en: 'Approve', zh: '赞同'),
    'celebrate': (en: 'Celebrate', zh: '庆祝'),
    'shy': (en: 'Shy', zh: '害羞'),
    'sweat': (en: 'Sweat', zh: '汗颜'),
    'sorry': (en: 'Sorry', zh: '抱歉'),
    'sad': (en: 'Sad', zh: '难过'),
    'pout': (en: 'Pout', zh: '嘟嘴'),
    'sleepy': (en: 'Sleepy', zh: '困了'),
  };

  static String figureAsset(String id) => 'assets/mascot/figures/svg/$id.svg';

  static String avatarAsset(String id) => '$_avatars/$id.png';

  static String expressionAsset(String id) => '$_expressions/$id.png';

  static String avatarName(String id, {required bool chinese}) {
    final entry = avatars[id];
    if (entry == null) return id;
    return chinese ? entry.zh : entry.en;
  }

  static String expressionName(String id, {required bool chinese}) {
    final entry = expressions[id];
    if (entry == null) return id;
    return chinese ? entry.zh : entry.en;
  }
}

/// Renders one bundled mascot asset by id.
///
/// The widget-test asset bundle does not serve directory-registered PNGs, so
/// a load failure degrades to an empty, layout-stable box instead of an
/// error; on device the bundled asset always renders.
enum _MascotArt { avatar, expression, figure }

class MascotImage extends StatelessWidget {
  const MascotImage.avatar(
    this.id, {
    super.key,
    required this.semanticLabel,
    this.size = 96,
  }) : _art = _MascotArt.avatar;

  const MascotImage.expression(
    this.id, {
    super.key,
    required this.semanticLabel,
    this.size = 96,
  }) : _art = _MascotArt.expression;

  /// The background-free figure art: the character on no painted
  /// backdrop, for cells that already supply their own fill.
  const MascotImage.figure(
    this.id, {
    super.key,
    required this.semanticLabel,
    this.size = 96,
  }) : _art = _MascotArt.figure;

  final String id;
  final String semanticLabel;
  final double size;
  final _MascotArt _art;

  /// A missing asset must stay visible: an empty box looks like a lost
  /// message in the transcript. Falls back to the mascot id chip.
  Widget _fallback(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: continuousHairlineDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(size / 4),
        stroke: colors.line,
      ),
      child: Text(
        id,
        style: TextStyle(fontSize: 11, color: colors.textMuted),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      child: _art == _MascotArt.figure
          ? SvgPicture.asset(
              MascotCatalog.figureAsset(id),
              width: size,
              height: size,
              fit: BoxFit.contain,
              placeholderBuilder: (context) =>
                  SizedBox(width: size, height: size),
              errorBuilder: (context, error, stackTrace) => _fallback(context),
            )
          : Image.asset(
              _art == _MascotArt.avatar
                  ? MascotCatalog.avatarAsset(id)
                  : MascotCatalog.expressionAsset(id),
              width: size,
              height: size,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (context, error, stackTrace) => _fallback(context),
            ),
    );
  }
}
