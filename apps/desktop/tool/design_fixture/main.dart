/// Development-only design bench.
///
/// Mounts the real production shells, layouts and feature surfaces over
/// synthetic presentation data so colours, materials, ambience, motion and
/// geometry are designed and reviewed in the rendered client with hot
/// reload. Never reachable from `lib/main.dart`; run only via
///
///   LICOUP_DESIGN_BENCH=1 LICO_CLIENT_SKIP_XCODE_SIDECAR_BUNDLE=1 \
///   LICOUP_HOME="$TMPDIR/licoup-design-home" flutter run -d macos \
///     -t tool/design_fixture/main.dart \
///     --dart-define=FIXTURE_LAYOUT=dashboard-a \
///     --dart-define=FIXTURE_THEME=dark
///
/// `LICOUP_DESIGN_BENCH=1` lets the debug bench run beside an installed
/// client; the fixture never spawns the sidecars, so their bundling is
/// skipped.
library;

import 'package:flutter/widgets.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/composition/client_app_composition.dart';

import 'fixture_services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = buildFixtureController();
  runApp(
    LicoApp(
      compositionFactory: () => ClientAppComposition(
        controller: controller,
        collaborationRunPort: fixtureCollaborationPort,
        pluginWindowHostPort: fixturePluginHost,
      ),
    ),
  );
  seedFixtureSurfaces();
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => applyFixtureDestination(controller),
  );
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => applyFixtureTour(controller),
  );
}
