import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show BuildContext, Theme;

bool isMobileClientTargetPlatform(TargetPlatform platform) {
  return platform == TargetPlatform.android || platform == TargetPlatform.iOS;
}

bool isMobileClientPlatform(BuildContext context) {
  return isMobileClientTargetPlatform(Theme.of(context).platform);
}

bool get isMobileClientDefaultPlatform {
  return isMobileClientTargetPlatform(defaultTargetPlatform);
}
