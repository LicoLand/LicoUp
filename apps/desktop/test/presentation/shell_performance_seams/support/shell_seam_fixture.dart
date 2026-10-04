import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/app.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/presentation_observation.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';

import '../../../fixtures/client_controller/support/fake_agent_service.dart';
import 'counted_shell_observation.dart';
import 'measurement_preferences.dart';
import 'shell_rebuild_counter.dart';

/// One counted measurement of a named ordinary shell interaction.
final class ShellInteractionMeasurement {
  const ShellInteractionMeasurement({
    required this.interaction,
    required this.widgetRebuilds,
    required this.framesPumped,
    required this.acceptedProjections,
    required this.frameConsumedProjections,
    required this.consumedFrames,
    required this.rendererIntents,
  });

  /// The named interaction, matching the registered workload definition.
  final String interaction;

  /// Widget rebuilds by widget type.
  final Map<String, int> widgetRebuilds;

  /// Frames the shell asked for after the interaction, under the virtual clock.
  final int framesPumped;

  /// Projections a rendering widget accepted for this interaction.
  final int acceptedProjections;

  /// Accepted projections a pumped frame consumed.
  final int frameConsumedProjections;

  /// Distinct frames that consumed a projection for this interaction.
  final int consumedFrames;

  /// Renderer intents the shell began for this interaction.
  final int rendererIntents;

  int get totalRebuilds =>
      widgetRebuilds.values.fold(0, (sum, value) => sum + value);

  int rebuildsMatching(String fragment) => widgetRebuilds.entries
      .where((entry) => entry.key.contains(fragment))
      .fold(0, (sum, entry) => sum + entry.value);

  @override
  String toString() =>
      'ShellInteractionMeasurement($interaction, rebuilds=$totalRebuilds, '
      'byWidget=$widgetRebuilds, frames=$framesPumped, '
      'accepted=$acceptedProjections, frameConsumed=$frameConsumedProjections, '
      'consumedFrames=$consumedFrames, intents=$rendererIntents)';
}

/// The real application shell, staged for counted interaction measurement.
///
/// The fixture mounts the production root ([LicoApp]) over the production
/// composition and drives it through the shell's own intentions and owners.
/// Only the backend is substituted, so every count comes from the real widget,
/// projection and composition seams rather than from a stand-in.
final class ShellSeamFixture {
  ShellSeamFixture._({
    required this.tester,
    required this.controller,
    required this.composition,
    required this.rebuilds,
    required this.dataRoot,
  });

  final WidgetTester tester;
  final ClientController controller;
  final ClientAppComposition composition;
  final ShellRebuildCounter rebuilds;

  /// Disposable data root, so a measurement never reads or writes the
  /// developer's own presentation preferences.
  final Directory dataRoot;
  Future<void>? _disposal;

  static Future<ShellSeamFixture> create(
    WidgetTester tester, {
    PresentationObservation? observation,
    ClientCompositionSet compositionSet = ClientCompositionSet.full,
    Widget Function(BuildContext, ShellBinding, ShellRendererPort)? homeBuilder,
  }) async {
    final dataRoot = Directory.systemTemp.createTempSync('licoup-shell-seams-');
    final controller = ClientController(
      agentService: FakeAgentService(),
      portableData: PortableDataRoot(dataDirectoryOverride: dataRoot),
      presentationPreferencesRepository: MeasurementPreferences(
        PresentationPreferences(
          layoutProfileId: LayoutProfileId.parse('dashboard'),
          appearancePresetId: AppearancePresetIds.licoSoda,
          localePreference: LocalePreference.english,
        ),
      ),
    );
    final composition = ClientAppComposition(
      controller: controller,
      telemetry: observation,
      compositionSet: compositionSet,
    );
    await tester.runAsync(controller.layoutManager.initialize);
    controller
      ..statusCaption = 'Ready'
      ..statusMessage = 'Deterministic measurement surface ready.';
    final rebuilds = ShellRebuildCounter()..install();
    // The mount carries a fresh key: without it a second fixture in the same
    // process updates the existing LicoApp element instead of mounting a new
    // one, and the measured shell would be the composition of the previous
    // fixture rather than the one this measurement owns.
    await tester.pumpWidget(
      LicoApp(
        key: UniqueKey(),
        compositionFactory: () => composition,
        initializeController: false,
        homeBuilder: homeBuilder,
      ),
    );
    await tester.pump();
    await tester.pump();
    return ShellSeamFixture._(
      tester: tester,
      controller: controller,
      composition: composition,
      rebuilds: rebuilds,
      dataRoot: dataRoot,
    );
  }

  ClientSection get currentSection => controller.currentSection;

  /// Counts one interaction: run [mutate], pump its frames, read the deltas.
  Future<ShellInteractionMeasurement> measure(
    String interaction,
    Future<void> Function() mutate, {
    required CountedShellObservation observation,
  }) async {
    rebuilds.clear();
    final acceptedBefore = observation.acceptedProjections;
    final consumedBefore = observation.frameConsumedProjections;
    final stampsBefore = observation.frameConsumptionStamps.length;
    final intentsBefore = observation.rendererIntents;

    await mutate();
    await tester.pump();
    await tester.pump();

    return ShellInteractionMeasurement(
      interaction: interaction,
      widgetRebuilds: Map<String, int>.of(rebuilds.byWidget),
      framesPumped: 2,
      acceptedProjections: observation.acceptedProjections - acceptedBefore,
      frameConsumedProjections:
          observation.frameConsumedProjections - consumedBefore,
      consumedFrames: observation.frameConsumptionStamps
          .sublist(stampsBefore)
          .toSet()
          .length,
      rendererIntents: observation.rendererIntents - intentsBefore,
    );
  }

  /// Switches the shell destination through the shell's own intent.
  void selectDestination(ClientSection destination) {
    composition.binding.intents.send(SelectShellDestination(destination));
  }

  /// Changes the appearance preset the shell projects.
  void changeAppearance(String presetId) {
    controller.appearancePreferenceOwner.replacePreset(presetId);
  }

  /// The layout profile the shell currently projects.
  LayoutProfileId get currentLayoutId =>
      controller.layoutManager.state.effectiveId;

  /// Changes the stored layout selection to another built-in profile.
  Future<void> changeLayout(LayoutProfileId profileId) async {
    await tester.runAsync(
      () => controller.layoutManager.selectLayout(profileId),
    );
  }

  /// Selects the built-in layout profile the shell is not showing.
  Future<void> switchLayout() => changeLayout(
    LayoutProfileId.parse(
      currentLayoutId.value == 'dashboard' ? 'desktop' : 'dashboard',
    ),
  );

  /// Releases the staged composition and the rebuild counter.
  ///
  /// Teardown owns this call: disposing the composition while its widget tree
  /// is still mounted is not a shell lifecycle this repository supports.
  Future<void> dispose() {
    return _disposal ??= () async {
      rebuilds.remove();
      await tester.runAsync(composition.dispose);
      if (dataRoot.existsSync()) dataRoot.deleteSync(recursive: true);
    }();
  }
}
