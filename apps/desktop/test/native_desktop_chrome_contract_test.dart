import 'package:flutter_client/src/frontend/layout/profiles/native/desktop/shell/native_desktop_chrome_metrics.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Native desktop profile cannot import `frontend/shared/ui`, so it
/// mirrors the frozen window-chrome contract privately. The macOS window
/// (`MainFlutterWindow.swift`) mirrors the same values natively. This test
/// pins the mirror to the shared authority so a one-sided edit fails here
/// instead of drifting the traffic-light alignment at runtime.
void main() {
  test('Native chrome metrics mirror the shared Apple chrome contract', () {
    expect(
      NativeDesktopChromeMetrics.topBarHeight,
      AppleControlMetrics.topBarHeight,
    );
    expect(
      NativeDesktopChromeMetrics.windowCornerRadius,
      AppleControlMetrics.windowCornerRadius,
    );
  });

  test('Native chrome corners stay concentric with the window corner', () {
    // The search capsule nests inside the window's top-trailing corner.
    expect(
      NativeDesktopChromeMetrics.searchFieldCornerRadius,
      NativeDesktopChromeMetrics.windowCornerRadius -
          NativeDesktopChromeMetrics.searchFieldEdgeInset,
    );
    // The band centers the capsule with the same inset it stands off the
    // trailing edge.
    expect(
      (NativeDesktopChromeMetrics.topBarHeight -
              NativeDesktopChromeMetrics.searchFieldHeight) /
          2,
      NativeDesktopChromeMetrics.searchFieldEdgeInset,
    );
    // The detail layer's leading corner stays tighter than the window
    // corner it meets.
    expect(
      NativeDesktopChromeMetrics.detailCornerRadius,
      lessThan(NativeDesktopChromeMetrics.windowCornerRadius),
    );
  });
}
