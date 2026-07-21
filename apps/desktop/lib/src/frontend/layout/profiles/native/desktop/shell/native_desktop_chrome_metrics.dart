import 'package:flutter/material.dart';

/// Native-private mirror of the frozen desktop window-chrome contract.
///
/// The cross-profile authority for the top band and window radius lives in
/// `AppleControlMetrics` (frontend/shared/ui), which layout profiles may not
/// import; `MainFlutterWindow.swift` mirrors the same values natively. Parity
/// between this mirror and the shared authority is locked by
/// `test/native_desktop_chrome_contract_test.dart`.
abstract final class NativeDesktopChromeMetrics {
  /// Top band height. The native traffic lights stay vertically centered
  /// inside this band (aligned on the Swift side); the icon rail keeps this
  /// zone clear and the layered content starts directly beneath it.
  static const double topBarHeight = 48;

  /// Outer window radius, concentric with the collapsed shell search circle:
  /// R_window = searchButtonRadius (16) + edgeInset (8) = 24.
  static const double windowCornerRadius = 24;

  /// The icon navigation rail stands directly on the window background — the
  /// shell's lowest layer together with the top band.
  static const double iconRailExtent = 64;

  /// Search capsule height inside the top band; the equal vertical inset is
  /// (topBarHeight − searchFieldHeight) / 2 = 10.
  static const double searchFieldHeight = 28;

  /// Trailing inset of the search capsule, concentric with the window's
  /// top-trailing corner.
  static const double searchFieldEdgeInset = 10;

  /// Search capsule corner radius, concentric with the window corner:
  /// R_search = R_window (24) − searchFieldEdgeInset (10) = 14.
  static const double searchFieldCornerRadius = 14;

  /// Top-leading radius of the third (detail) card where it meets the
  /// layers behind it.
  static const double detailCornerRadius = 14;

  /// The detail card stands off the window's trailing and bottom edges by
  /// this much; its leading and top edges rest against the layers behind.
  static const double detailCardMargin = 10;

  /// Inset of the nested conversation detail card inside the workspace
  /// container (top, trailing, and bottom edges).
  static const double detailInset = 6;

  /// Corner radius of the nested conversation detail card.
  static const double innerDetailCornerRadius = 10;

  /// Retina hairline shared by every Native glass edge.
  static const double hairline = 0.5;

  static BorderRadius get windowBorderRadius =>
      BorderRadius.circular(windowCornerRadius);
}
