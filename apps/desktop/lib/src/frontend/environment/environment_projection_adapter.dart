import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shell/client_platform.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

Locale? localeFromProjection(LocaleProjection projection) =>
    LicoStrings.localeForPreference(projection.preference);

LayoutEnvironment collectLayoutEnvironment(
  BuildContext context,
  BoxConstraints constraints,
  LayoutRuntimeSurface projectedSurface,
) {
  final media = MediaQuery.of(context);
  final mobile =
      projectedSurface == LayoutRuntimeSurface.mobile ||
      isMobileClientPlatform(context);
  return LayoutEnvironment.fromConstraints(
    surface: mobile
        ? LayoutRuntimeSurface.mobile
        : LayoutRuntimeSurface.desktop,
    width: constraints.maxWidth,
    height: constraints.maxHeight,
    textScale: media.textScaler.scale(1),
    safeInsets: LayoutInsets(
      left: media.padding.left,
      top: media.padding.top,
      right: media.padding.right,
      bottom: media.padding.bottom,
    ),
    keyboardInset: media.viewInsets.bottom,
    hasPointer: !mobile,
    hasKeyboard: !mobile,
    hasTouch: mobile,
    reducedMotion: media.disableAnimations,
  );
}

({String message, String caption, String errorCode}) resolveStatusProjection(
  StatusProjection status,
  LocaleProjection locale,
) {
  final strings = LicoStrings.forPreference(locale.preference);
  return (
    message: strings.isChinese ? status.messageChinese : status.messageEnglish,
    caption: strings.statusCaptionLabel(status.caption),
    errorCode: status.errorCode,
  );
}
