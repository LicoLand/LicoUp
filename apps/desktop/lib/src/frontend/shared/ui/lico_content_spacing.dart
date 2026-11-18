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

  /// Horizontal inset shared by a feature-pane title bar and its content
  /// container, so the title left edge lines up with the container left edge.
  static const double paneInset = section;

  /// Equal gap above the title and between the title and the content
  /// container.
  static const double paneTitleGap = 18;

  /// Inner padding of the feature-pane content container. Top matches
  /// [paneTitleGap]; the other sides keep [paneInset] so cards stay aligned
  /// with the title bar.
  static const EdgeInsets paneContentPadding = EdgeInsets.fromLTRB(
    paneInset,
    paneTitleGap,
    paneInset,
    paneInset,
  );

  /// Title-bar padding: same horizontal inset as the container, matching
  /// [paneTitleGap] above the title, and no extra gap below — the container's
  /// top padding is the title-to-content gap.
  static const EdgeInsets paneTitlePadding = EdgeInsets.fromLTRB(
    paneInset,
    paneTitleGap,
    paneInset,
    0,
  );
}
