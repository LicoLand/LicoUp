import 'package:flutter/widgets.dart';

/// Project-wide content rhythm. Adjacent peer content must use [item] or a
/// larger token; compact spacing is reserved for content inside one component.
abstract final class LicoContentSpacing {
  static const double inline = 4;
  static const double compact = 8;
  static const double item = 16;
  static const double section = 24;

  static const EdgeInsets page = EdgeInsets.all(item);
  static const EdgeInsets peerItem = EdgeInsets.only(bottom: item);
}
