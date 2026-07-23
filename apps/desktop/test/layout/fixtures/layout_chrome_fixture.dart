import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

/// Explicit test-only shell chrome boundary for renderer harnesses.
final class FixtureLayoutChromePort implements LayoutChromePort {
  const FixtureLayoutChromePort();

  @override
  LayoutChromeSnapshot get value => const LayoutChromeSnapshot.empty();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> openPairing(BuildContext context) async {}

  @override
  Future<void> openGlobalSearch(BuildContext context) async {}
}
