import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

/// The mount directory is the one place that decides what a client contributes,
/// so these cases drive its own lifecycle — mount, unmount, enable — and assert
/// the contributions follow the declaration and nothing else.
void main() {
  const agents = FeatureMountId('agents');
  const settings = FeatureMountId('settings');
  const skillHub = FeatureMountId('skill-hub');
  const agentsDestination = MountDestinationId('agents');
  const settingsDestination = MountDestinationId('settings');
  const skillDestination = MountDestinationId('skill-hub');
  const agentCatalog = MountCapabilityId('agent-catalog');
  const skillCatalogue = MountCapabilityId('skill-catalogue');
  const settingsCapability = MountCapabilityId('presentation-settings');

  FeatureMountDirectory directory() =>
      FeatureMountDirectory(<FeatureMountRequest>[
        FeatureMountRequest(
          id: agents,
          phase: FeatureMountPhase.enabled,
          destinations: const <MountDestinationId>[agentsDestination],
          capabilities: const <MountCapabilityId>[agentCatalog],
        ),
        FeatureMountRequest(
          id: settings,
          phase: FeatureMountPhase.enabled,
          destinations: const <MountDestinationId>[settingsDestination],
          capabilities: const <MountCapabilityId>[settingsCapability],
        ),
        FeatureMountRequest(
          id: skillHub,
          phase: FeatureMountPhase.enabled,
          destinations: const <MountDestinationId>[skillDestination],
          capabilities: const <MountCapabilityId>[skillCatalogue],
        ),
      ]);

  test('an enabled entry contributes exactly what it declares', () {
    final mounts = directory();

    expect(mounts.contributorOf(agentsDestination)?.id, agents);
    expect(mounts.contributorOf(skillDestination)?.id, skillHub);
    expect(mounts.contributes(settingsDestination), isTrue);
    expect(mounts.contributesCapability(skillCatalogue), isTrue);
    expect(
      mounts.contributesCapabilities(<MountCapabilityId>[
        agentCatalog,
        settingsCapability,
      ]),
      isTrue,
    );
    expect(mounts.destinations, <MountDestinationId>{
      agentsDestination,
      settingsDestination,
      skillDestination,
    });
    expect(mounts.capabilities, <MountCapabilityId>{
      agentCatalog,
      settingsCapability,
      skillCatalogue,
    });
    expect(mounts.entryFor(agents)?.destinations, <MountDestinationId>{
      agentsDestination,
    });
  });

  test('mounting an entry owns it without contributing anything', () {
    final mounted = directory().mount(skillHub);

    expect(mounted.isMounted(skillHub), isTrue);
    expect(mounted.isEnabled(skillHub), isFalse);
    expect(mounted.phaseOf(skillHub), FeatureMountPhase.mounted);
    expect(mounted.contributes(skillDestination), isFalse);
    expect(mounted.contributorOf(skillDestination), isNull);
    expect(mounted.contributesCapability(skillCatalogue), isFalse);
    expect(mounted.capabilities, isNot(contains(skillCatalogue)));
    expect(
      mounted.entryFor(skillHub)?.destinations,
      <MountDestinationId>{skillDestination},
      reason: 'the declaration is kept; only the phase decides contribution',
    );
    expect(
      mounted.enable(skillHub).contributes(skillDestination),
      isTrue,
      reason: 'enabling restores exactly the declared contribution',
    );
  });

  test('unmounting an entry withdraws everything it contributed', () {
    final unmounted = directory().unmount(skillHub);

    expect(unmounted.entryFor(skillHub), isNotNull);
    expect(unmounted.isMounted(skillHub), isFalse);
    expect(unmounted.phaseOf(skillHub), FeatureMountPhase.unmounted);
    expect(unmounted.contributes(skillDestination), isFalse);
    expect(unmounted.contributesCapability(skillCatalogue), isFalse);
    expect(
      unmounted.contributes(agentsDestination),
      isTrue,
      reason: 'unmounting one entry leaves the others alone',
    );
  });

  test('removing a declaration removes its contribution entirely', () {
    final withoutSkillHub = directory().without(<FeatureMountId>[skillHub]);

    expect(withoutSkillHub.entryFor(skillHub), isNull);
    expect(withoutSkillHub.mounts.length, 2);
    expect(withoutSkillHub.contributes(skillDestination), isFalse);
    expect(withoutSkillHub.contributesCapability(skillCatalogue), isFalse);
    expect(withoutSkillHub.contributes(agentsDestination), isTrue);
    expect(
      withoutSkillHub.without(<FeatureMountId>[const FeatureMountId('absent')]),
      withoutSkillHub,
      reason: 'removing an undeclared identity is a no-op',
    );
  });

  test('a phase transition never creates a declaration', () {
    expect(
      () => directory().unmount(const FeatureMountId('absent')),
      throwsArgumentError,
    );
    expect(
      () => directory().enable(const FeatureMountId('absent')),
      throwsArgumentError,
    );
    expect(
      () => FeatureMountDirectory(<FeatureMountRequest>[
        FeatureMountRequest(id: agents),
        FeatureMountRequest(id: agents),
      ]),
      throwsArgumentError,
    );
  });

  test('the first enabled contributor answers a destination', () {
    final shared = FeatureMountDirectory(<FeatureMountRequest>[
      FeatureMountRequest(
        id: agents,
        phase: FeatureMountPhase.unmounted,
        destinations: const <MountDestinationId>[agentsDestination],
      ),
      FeatureMountRequest(
        id: settings,
        phase: FeatureMountPhase.enabled,
        destinations: const <MountDestinationId>[agentsDestination],
      ),
    ]);

    expect(shared.contributorOf(agentsDestination)?.id, settings);
    expect(shared.mounts.length, 2);
  });

  test('two directories with the same declarations are equal', () {
    expect(directory(), directory());
    expect(directory().hashCode, directory().hashCode);
    expect(directory(), isNot(directory().unmount(skillHub)));
    expect(FeatureMountDirectory.empty, isNot(directory()));
    expect(FeatureMountDirectory.empty.destinations, isEmpty);
    expect(FeatureMountDirectory.empty.isNotEmpty, isFalse);
    expect(FeatureMountDirectory.empty.contributes(agentsDestination), isFalse);
  });

  test('a declaration is immutable input, not a lifecycle holder', () {
    final request = FeatureMountRequest(
      id: agents,
      phase: FeatureMountPhase.enabled,
      destinations: const <MountDestinationId>[agentsDestination],
      capabilities: const <MountCapabilityId>[agentCatalog],
    );

    expect(
      request.at(FeatureMountPhase.unmounted).phase,
      FeatureMountPhase.unmounted,
    );
    expect(request.phase, FeatureMountPhase.enabled);
    expect(request.enabled(), request);
    expect(request.unmounted(), isNot(request));
    expect(request.entry.contributesDestination(agentsDestination), isTrue);
    expect(
      request.unmounted().entry.contributesDestination(agentsDestination),
      isFalse,
    );
    expect(request.destinations, <MountDestinationId>{agentsDestination});
    expect(
      () => request.destinations.add(const MountDestinationId('other')),
      throwsUnsupportedError,
    );
  });
}
