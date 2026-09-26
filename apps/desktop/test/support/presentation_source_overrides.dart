import 'package:flutter_test/flutter_test.dart';

/// Shared support for tests whose view reads a migrated presentation region.
///
/// Such a view renders its region from a runtime source (installed with the
/// production `*PresentationSource` adapter through the region provider), so the
/// first frame arrives asynchronously. These helpers keep the wait tied to a
/// visible element instead of a fixed sleep or an unbounded `pumpAndSettle`.

/// Pumps bounded frames until [finder] matches.
///
/// Returns whether it became visible within [maxFrames].
Future<bool> pumpUntilVisible(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 20,
  Duration frame = const Duration(milliseconds: 10),
}) async {
  for (var attempt = 0; attempt < maxFrames; attempt += 1) {
    if (finder.evaluate().isNotEmpty) return true;
    await tester.pump(frame);
  }
  return finder.evaluate().isNotEmpty;
}
