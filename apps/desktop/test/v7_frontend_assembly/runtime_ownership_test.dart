// V7-FI: one app-scope presentation runtime with exactly one owner.
//
// The composition root owns the only runtime and installs it through
// `presentationOverrides`, so the mounted shell providers and the renderer
// chrome share one observation store. These tests prove the two failure modes
// the ownership rule guards against: a second runtime instance for the mounted
// tree, and disposal by the wrong owner (the scope disposing the runtime, or
// the runtime being disposed twice).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/presentation/shell/shell_providers.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';
import '../presentation/composed_client_shell_test_helper.dart';
import '../support/presentation_source_overrides.dart';

const _shellSize = Size(1180, 760);

void main() {
  test(
    'the composition runtime outlives the scope and closes exactly once',
    () async {
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('dashboard'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.agentHub,
        size: _shellSize,
        brightness: Brightness.dark,
      );
      addTearDown(fixture.dispose);
      final composition = ClientAppComposition(controller: fixture.controller);
      final runtime = composition.presentationRuntime;
      final container = ProviderContainer(
        overrides: composition.presentationOverrides,
      );
      expect(
        identical(container.read(presentationRuntimeProvider), runtime),
        isTrue,
        reason: 'the scope must install the composition runtime',
      );

      // Disposing the scope must not dispose the composition-owned runtime.
      container.dispose();
      expect(
        await _admits(runtime, composition.shellSources.status),
        isTrue,
        reason: 'the scope disposed a runtime it does not own',
      );

      await composition.dispose();
      await composition.dispose();
      expect(
        () => runtime.observe(composition.shellSources.status),
        throwsStateError,
        reason: 'the composition must close exactly the runtime it owns',
      );
    },
  );

  testWidgets('the mounted tree shares the composition runtime', (
    tester,
  ) async {
    final fixture = await ProductionClientShellFixture.create(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      destination: ClientSection.agentHub,
      size: _shellSize,
      brightness: Brightness.dark,
    );
    addTearDown(fixture.dispose);
    final compositions = <ClientAppComposition>[];
    await tester.binding.setSurfaceSize(_shellSize);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLicoTheme(
          presetId: 'default-system',
          platformBrightness: Brightness.dark,
        ).copyWith(platform: TargetPlatform.macOS),
        home: MediaQuery(
          data: const MediaQueryData(
            size: _shellSize,
            devicePixelRatio: 1,
            textScaler: TextScaler.noScaling,
            platformBrightness: Brightness.dark,
            disableAnimations: true,
          ),
          child: composedClientShell(
            fixture.controller,
            onComposed: compositions.add,
          ),
        ),
      ),
    );
    expect(
      await pumpUntilVisible(
        tester,
        find.byKey(
          Key(
            'layout-host-dashboard/desktop/'
            '${LayoutViewportPolicy.classify(surface: LayoutRuntimeSurface.desktop, width: _shellSize.width).name}',
          ),
        ),
        maxFrames: 60,
      ),
      isTrue,
      reason: 'the real shell never became visible',
    );
    final composition = compositions.single;
    final runtime = composition.presentationRuntime;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ClientShell)),
    );
    expect(
      identical(container.read(presentationRuntimeProvider), runtime),
      isTrue,
      reason: 'the mounted tree opened a second runtime',
    );

    // The navigation region is watched by the shell providers but never by the
    // renderer chrome, so its admitted value proves the mounted providers went
    // through the composition runtime's single observation store.
    expect(runtime.current(shellNavigationPresentationFields), isNotNull);

    // Unmounting the scope must leave the composition-owned runtime alive.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(
      runtime.current(shellNavigationPresentationFields),
      isNotNull,
      reason: 'unmounting the scope disposed the composition runtime',
    );

    await tester.runAsync(composition.dispose);
    expect(
      () => runtime.observe(composition.shellSources.status),
      throwsStateError,
    );
  });
}

Future<bool> _admits<T>(
  PresentationRuntime runtime,
  PresentationSource<T> source,
) async {
  final observation = runtime.observe(source);
  ResourceSnapshot<T>? first;
  final subscription = observation.stream.listen((snapshot) {
    first ??= snapshot;
  });
  for (var attempt = 0; attempt < 60 && first == null; attempt++) {
    await pumpEventQueue(times: 2);
  }
  await subscription.cancel();
  await observation.close();
  return first != null;
}
