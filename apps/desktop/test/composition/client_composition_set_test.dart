import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/composition/client_feature_mounts.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

/// The declaration is the mount directory: these tests assert that mounting and
/// unmounting a feature's declaration — never a per-destination table — decides
/// which feature compositions a running client owns, and which destinations and
/// capabilities the shell can serve.
void main() {
  test('the minimum declaration mounts only the shell-owned features', () {
    final minimum = ClientCompositionSet.minimum;

    expect(minimum.agents, isTrue);
    expect(minimum.conversation, isTrue);
    expect(minimum.targets, isTrue);
    expect(minimum.chrome, isTrue);
    expect(minimum.monitoring, isTrue);
    expect(minimum.agentHub, isFalse);
    expect(minimum.mobileRelay, isFalse);
    expect(minimum.models, isFalse);
    expect(minimum.pluginManagement, isFalse);
    expect(minimum.search, isFalse);
    expect(minimum.settings, isFalse);
    expect(minimum.skillHub, isFalse);
    for (final mount in ClientFeatureMounts.all) {
      expect(
        minimum.phaseOf(mount.id),
        mount.shellOwned
            ? FeatureMountPhase.enabled
            : FeatureMountPhase.unmounted,
        reason: '${mount.id} must follow its own declaration',
      );
    }
  });

  test('the full declaration mounts every declared feature', () {
    final full = ClientCompositionSet.full;
    final minimum = ClientCompositionSet.minimum;

    expect(full.agents, isTrue);
    expect(full.conversation, isTrue);
    expect(full.targets, isTrue);
    expect(full.chrome, isTrue);
    expect(full.monitoring, isTrue);
    expect(full.agentHub, isTrue);
    expect(full.mobileRelay, isTrue);
    expect(full.models, isTrue);
    expect(full.pluginManagement, isTrue);
    expect(full.search, isTrue);
    expect(full.settings, isTrue);
    expect(full.skillHub, isTrue);
    expect(full.agentHub && !minimum.agentHub, isTrue);
    expect(full.mobileRelay && !minimum.mobileRelay, isTrue);
    expect(full.models && !minimum.models, isTrue);
    expect(full.pluginManagement && !minimum.pluginManagement, isTrue);
    expect(full.search && !minimum.search, isTrue);
    expect(full.settings && !minimum.settings, isTrue);
    expect(full.skillHub && !minimum.skillHub, isTrue);
  });

  test(
    'every destination is contributed by the declaration of one feature',
    () {
      for (final destination in ClientSection.values) {
        final contributor = ClientCompositionSet.full.mounts.contributorOf(
          mountDestinationOf(destination),
        );
        expect(contributor, isNotNull, reason: '$destination');
        expect(
          ClientCompositionSet.full.mounts.mounts
              .where(
                (entry) => entry.destinations.contains(
                  mountDestinationOf(destination),
                ),
              )
              .length,
          1,
          reason: '$destination must be declared by exactly one mount',
        );
        expect(
          ClientCompositionSet.minimum.isInstalled(destination),
          destination == ClientSection.agents ||
              destination == ClientSection.monitoring,
          reason: '$destination',
        );
      }
    },
  );

  test('the directory identity of a destination is its own name', () {
    for (final destination in ClientSection.values) {
      expect(mountDestinationOf(destination).value, destination.name);
      expect(clientSectionOf(mountDestinationOf(destination)), destination);
    }
    expect(
      clientSectionOf(const MountDestinationId('not-a-destination')),
      isNull,
    );
  });

  test('a capability is available only while its mount is mounted', () {
    expect(
      ClientCompositionSet.full.capabilities,
      containsAll(<MountCapabilityId>[
        ClientCapabilities.agentCatalog,
        ClientCapabilities.conversationPlanes,
        ClientCapabilities.targetCatalog,
        ClientCapabilities.rendererChrome,
        ClientCapabilities.agentUsage,
        ClientCapabilities.agentHub,
        ClientCapabilities.crossDeviceRelay,
        ClientCapabilities.modelCatalogue,
        ClientCapabilities.adapterPlugins,
        ClientCapabilities.globalSearch,
        ClientCapabilities.presentationSettings,
        ClientCapabilities.skillCatalogue,
      ]),
    );
    expect(
      ClientCompositionSet.minimum.capabilities,
      isNot(contains(ClientCapabilities.modelCatalogue)),
    );
    expect(
      ClientCompositionSet.full.mounts.contributesCapability(
        ClientCapabilities.modelCatalogue,
      ),
      isTrue,
    );
  });

  test('the catalogue projects the declaration it is given', () {
    final agentsOnly = ClientAppComposition(
      controller: ClientController(),
      compositionSet: ClientCompositionSet.fromRequests(<FeatureMountRequest>[
        for (final request in ClientFeatureMounts.full)
          request.id == ClientFeatureMounts.agents.id
              ? request
              : request.unmounted(),
      ]),
    );
    addTearDown(agentsOnly.dispose);

    expect(agentsOnly.mountedDestinations.destinations, const [
      ClientSection.agents,
    ]);
    expect(agentsOnly.binding.navigation.current.destinations, const [
      ClientSection.agents,
    ]);
    expect(
      agentsOnly.binding.navigation.current.unavailable,
      isNot(contains(ClientSection.agents)),
      reason: 'the one declared capability is not reported absent',
    );
  });
}
