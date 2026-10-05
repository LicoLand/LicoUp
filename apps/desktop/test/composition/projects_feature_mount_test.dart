import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/client_feature_mounts.dart';

import '../fixtures/project_surface_fixture.dart';

/// The project canvas is mounted through the same directory every other feature
/// uses: one declaration names its capability, the declaration selects which
/// clients own it, and the composition installs the binding exactly while the
/// declaration holds the mount.
void main() {
  test('the project canvas is an optional mount with its own capability', () {
    final declaration = ClientFeatureMounts.projects;

    expect(declaration.shellOwned, isFalse);
    expect(declaration.request.phase, FeatureMountPhase.enabled);
    expect(
      declaration.request.destinations,
      isEmpty,
      reason:
          'the canvas is a region of the shell, not a destination of its own',
    );
    expect(declaration.request.capabilities, const <MountCapabilityId>[
      ClientCapabilities.projectCanvas,
    ]);
    expect(ClientFeatureMounts.all, contains(declaration));
    expect(ClientCompositionSet.full.projects, isTrue);
    expect(
      ClientCompositionSet.minimum.projects,
      isFalse,
      reason: 'the minimum client owns no project surface',
    );
    expect(
      ClientCompositionSet.full.capabilities,
      contains(ClientCapabilities.projectCanvas),
    );
    expect(
      ClientCompositionSet.minimum.capabilities,
      isNot(contains(ClientCapabilities.projectCanvas)),
    );
  });

  testWidgets(
    'the composed client binds the canvas while its mount is enabled',
    (tester) async {
      final full = ClientAppComposition(
        controller: ClientController(),
        projectGateway: twoProjectGateway(),
      );
      addTearDown(full.dispose);
      await tester.pumpWidget(const SizedBox());

      expect(
        full.compositionSet.isFeatureMounted(ClientFeatureMounts.projects.id),
        isTrue,
      );
      expect(full.projects, isNotNull);
      expect(full.projects!.projection.current.projects, isEmpty);
      expect(
        full.shellDestinations.surface.projects,
        same(full.projects),
        reason: 'the catalogue serves the binding the composition installed',
      );
      expect(
        full.shellDestinations.catalogue
            .mountForId(ClientFeatureMounts.projects.id)
            ?.surface,
        isNotNull,
        reason: 'the mounted entry compiles the canvas surface',
      );
    },
  );

  testWidgets('an undeclared project mount installs no binding and no surface', (
    tester,
  ) async {
    final minimum = ClientAppComposition(
      controller: ClientController(),
      compositionSet: ClientCompositionSet.minimum,
      projectGateway: twoProjectGateway(),
    );
    addTearDown(minimum.dispose);
    await tester.pumpWidget(const SizedBox());

    expect(minimum.compositionSet.projects, isFalse);
    expect(minimum.projects, isNull);
    expect(
      minimum.shellDestinations.surface.projects,
      isNull,
      reason:
          'an unmounted feature contributes no binding, so the canvas surface '
          'has nothing to render',
    );
  });

  testWidgets(
    'a client with no injected project owner keeps the fail-closed lane',
    (tester) async {
      final composition = ClientAppComposition(controller: ClientController());
      addTearDown(composition.dispose);
      await tester.pumpWidget(const SizedBox());

      expect(
        composition.projects,
        isNotNull,
        reason:
            'the canvas is mounted, and it states that no owner is bound '
            'instead of presenting an empty project list',
      );
      expect(composition.projects!.projection.current.projects, isEmpty);
    },
  );
}
