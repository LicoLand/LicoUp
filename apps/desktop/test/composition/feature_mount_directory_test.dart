import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/binding_shell_renderer/shell_destinations.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/client_feature_mounts.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/features/models/ui/models_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/environment/workspace_home_directory_scope.dart';

/// The host's real rendering path decides what is mounted by asking the mount
/// directory, so these cases change the directory itself — a declaration is
/// removed, never a flag flipped — and then assert what the production renderer
/// does with the capability that declaration used to provide.
void main() {
  ClientAppComposition compositionFor(List<FeatureMountRequest> requests) {
    final composition = ClientAppComposition(
      controller: ClientController(),
      compositionSet: ClientCompositionSet.fromRequests(requests),
    );
    addTearDown(composition.dispose);
    return composition;
  }

  testWidgets(
    'removing a feature mount declaration removes its destination from the '
    'renderer',
    (tester) async {
      final complete = compositionFor(ClientFeatureMounts.full);
      final composition = compositionFor(
        ClientFeatureMounts.without(<FeatureMountId>[
          ClientFeatureMounts.models.id,
        ]),
      );

      // The declaration is gone from the directory, so the directory reports
      // the capability absent and the composition owns no owner for it.
      expect(
        composition.compositionSet.mounts.entryFor(
          ClientFeatureMounts.models.id,
        ),
        isNull,
      );
      expect(composition.compositionSet.models, isFalse);
      expect(
        composition.compositionSet.mounts.contributesCapability(
          ClientCapabilities.modelCatalogue,
        ),
        isFalse,
      );
      expect(
        composition.compositionSet.mounts.contributorOf(
          mountDestinationOf(ClientSection.models),
        ),
        isNull,
      );

      // The catalogue projection and the shell navigation plane follow the
      // directory.
      expect(
        composition.mountedDestinations.isMounted(ClientSection.models),
        isFalse,
      );
      expect(
        composition.binding.navigation.current.destinations,
        isNot(contains(ClientSection.models)),
      );
      expect(
        composition.binding.navigation.current.unavailable,
        contains(ClientSection.models),
      );

      // The production path the shell uses — ClientShell builds through
      // ShellRendererPort.buildDestination — renders nothing for the
      // destination the removed declaration used to contribute.
      await tester.pumpWidget(const SizedBox());
      final context = tester.element(find.byType(SizedBox));
      expect(
        complete.renderer.buildDestination(
          context,
          ClientSection.models,
          agentsHomeKey: complete.renderer.createAgentsHomeKey(),
        ),
        isA<ModelsPanel>(),
        reason: 'the declaration is what serves the destination',
      );
      expect(
        composition.renderer.buildDestination(
          context,
          ClientSection.models,
          agentsHomeKey: composition.renderer.createAgentsHomeKey(),
        ),
        same(ShellDestinations.absentSurface),
      );

      // Neighbouring mounts are untouched: removal is not a global shutdown.
      expect(
        composition.renderer.buildDestination(
          context,
          ClientSection.agents,
          agentsHomeKey: composition.renderer.createAgentsHomeKey(),
        ),
        isA<WorkspaceHomeDirectoryScope>(),
      );
      expect(
        composition.renderer.buildDestination(
          context,
          ClientSection.monitoring,
          agentsHomeKey: composition.renderer.createAgentsHomeKey(),
        ),
        isA<AgentUsagePanel>(),
      );
    },
  );

  testWidgets('the directory decides which feature serves a destination', (
    tester,
  ) async {
    // The minimum declaration leaves the model catalog unmounted and the skill
    // hub's own declaration contributes the model catalog destination in its
    // place. Nothing about the destination identity says which feature serves
    // it, so a renderer that dispatched on the destination would build the wrong
    // panel; a renderer that asks the directory builds the contributor's own
    // surface.
    final skillHub = ClientFeatureMounts.skillHub.request;
    final remapped = <FeatureMountRequest>[
      for (final request in ClientFeatureMounts.minimum)
        if (request.id != ClientFeatureMounts.models.id)
          request.id == skillHub.id
              ? FeatureMountRequest(
                  id: skillHub.id,
                  phase: skillHub.phase,
                  destinations: <MountDestinationId>[
                    ...skillHub.destinations,
                    mountDestinationOf(ClientSection.models),
                  ],
                  capabilities: skillHub.capabilities,
                )
              : request,
    ];
    final composition = compositionFor(remapped);

    expect(
      composition.compositionSet.mounts
          .contributorOf(mountDestinationOf(ClientSection.models))
          ?.id,
      skillHub.id,
    );
    expect(
      composition.shellDestinations.catalogue
          .mountForDestination(mountDestinationOf(ClientSection.models))
          ?.id,
      skillHub.id,
    );

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));
    expect(
      composition.renderer.buildDestination(
        context,
        ClientSection.models,
        agentsHomeKey: composition.renderer.createAgentsHomeKey(),
      ),
      isA<SkillHubPanel>(),
      reason: 'the contributor the directory names serves the destination',
    );
    expect(
      composition.renderer.buildDestination(
        context,
        ClientSection.skillHub,
        agentsHomeKey: composition.renderer.createAgentsHomeKey(),
      ),
      isA<SkillHubPanel>(),
    );
    expect(
      composition.renderer.buildDestination(
        context,
        ClientSection.settings,
        agentsHomeKey: composition.renderer.createAgentsHomeKey(),
      ),
      same(ShellDestinations.absentSurface),
      reason: 'the settings declaration is unchanged and still unmounted',
    );
  });

  testWidgets('a mount whose required capability is gone projects no surface', (
    tester,
  ) async {
    final complete = compositionFor(ClientFeatureMounts.full);
    final withoutModels = compositionFor(
      ClientFeatureMounts.without(<FeatureMountId>[
        ClientFeatureMounts.models.id,
      ]),
    );

    await tester.pumpWidget(const SizedBox());
    final context = tester.element(find.byType(SizedBox));

    // The relay destination renders its pairing channels from the model
    // catalogue, so it declares that capability as a requirement.
    final relayMount = complete.shellDestinations.catalogue.mountForId(
      ClientFeatureMounts.mobileRelay.id,
    );
    expect(relayMount, isNotNull);
    expect(relayMount!.requires, contains(ClientCapabilities.modelCatalogue));
    expect(
      complete.shellDestinations.catalogue.serves(relayMount),
      isTrue,
      reason: 'the full declaration contributes the required capability',
    );
    expect(
      complete.renderer.buildDestination(
        context,
        ClientSection.mobileRelay,
        agentsHomeKey: complete.renderer.createAgentsHomeKey(),
      ),
      isA<MobileRelayPanel>(),
    );

    // With the model catalog declaration removed the relay mount is still
    // enabled and still contributes its own destination, but the capability it
    // requires is unavailable, so the renderer serves no surface instead of
    // rendering from a binding that is no longer installed.
    expect(
      withoutModels.compositionSet.mounts.isEnabled(
        ClientFeatureMounts.mobileRelay.id,
      ),
      isTrue,
    );
    expect(
      withoutModels.compositionSet.mounts.contributesCapability(
        ClientCapabilities.crossDeviceRelay,
      ),
      isTrue,
    );
    expect(
      withoutModels.compositionSet.mounts.contributesCapability(
        ClientCapabilities.modelCatalogue,
      ),
      isFalse,
    );
    expect(
      withoutModels.shellDestinations.catalogue.serves(relayMount),
      isFalse,
    );
    expect(
      withoutModels.renderer.buildDestination(
        context,
        ClientSection.mobileRelay,
        agentsHomeKey: withoutModels.renderer.createAgentsHomeKey(),
      ),
      same(ShellDestinations.absentSurface),
    );
  });

  testWidgets('the renderer resolves destinations against the composition '
      'directory itself', (tester) async {
    final composition = compositionFor(ClientFeatureMounts.full);

    // One directory: the declaration the root was given, the catalogue the
    // renderer resolves with, and the projection the navigation plane reads.
    expect(
      identical(
        composition.shellDestinations.catalogue.directory,
        composition.compositionSet.mounts,
      ),
      isTrue,
    );
    expect(
      identical(
        composition.shellDestinations.composition,
        composition.compositionSet,
      ),
      isTrue,
    );

    for (final destination in ClientSection.values) {
      final contributor = composition.compositionSet.mounts.contributorOf(
        mountDestinationOf(destination),
      );
      expect(contributor, isNotNull, reason: '$destination');
      expect(
        composition.shellDestinations.catalogue
            .mountForDestination(mountDestinationOf(destination))
            ?.id,
        contributor!.id,
        reason: '$destination must resolve through its contributor',
      );
    }
  });

  test('unmounting a declaration stops its capability without removing it', () {
    final unmounted = ClientCompositionSet.fromRequests(<FeatureMountRequest>[
      for (final request in ClientFeatureMounts.full)
        request.id == ClientFeatureMounts.skillHub.id
            ? request.unmounted()
            : request,
    ]);

    expect(
      unmounted.mounts.entryFor(ClientFeatureMounts.skillHub.id),
      isNotNull,
      reason: 'unmounting keeps the declaration',
    );
    expect(unmounted.skillHub, isFalse);
    expect(
      unmounted.mounts.contributesCapability(ClientCapabilities.skillCatalogue),
      isFalse,
    );
    expect(unmounted.isInstalled(ClientSection.skillHub), isFalse);
    expect(
      unmounted.isInstalled(ClientSection.settings),
      isTrue,
      reason: 'unmounting one feature leaves the rest of the client intact',
    );
    expect(
      unmounted.capabilities,
      isNot(contains(ClientCapabilities.skillCatalogue)),
    );
    expect(
      unmounted.capabilities,
      contains(ClientCapabilities.presentationSettings),
    );
  });
}
