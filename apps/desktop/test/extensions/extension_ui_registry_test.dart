import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/src/extensions/extension_ui.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'extension_ui_test_support.dart';

void main() {
  late PresentationRuntime runtime;

  setUp(() {
    runtime = PresentationRuntime();
  });

  tearDown(() {
    runtime.dispose();
  });

  ExtensionUiRegistrySnapshot settingsEpoch({
    required int epoch,
    required String resourceRef,
    String instanceId = 'instance-1',
    int generation = 1,
    String actionRef = 'action:test.save',
    Set<String> servedProfiles = const <String>{'declarative-ui'},
  }) => ExtensionUiRegistrySnapshot.fromJson(
    extensionEpochDocument(
      registryEpoch: epoch,
      servedProfiles: servedProfiles,
      contributions: <Map<String, Object?>>[
        extensionContributionJson(
          id: 'vendor.example.form',
          kind: 'settings',
          title: 'Endpoint',
          resourceRef: resourceRef,
          actionRef: actionRef,
          instanceId: instanceId,
          generation: generation,
          fields: <Map<String, Object?>>[
            extensionFieldJson(id: 'endpoint', label: 'Endpoint', type: 'text'),
          ],
        ),
      ],
    ),
  );

  test('mounting an epoch observes the resource and installs a prepared value',
      () async {
    final field = syntheticExtensionField('form-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://local'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.form',
          source: source,
        ),
      );
    final actions = RecordingExtensionActions();
    bindings.registerAction('action:test.save', actions);
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(settingsEpoch(epoch: 1, resourceRef: 'resource:test.form'));
    await pumpEventQueue();

    final session = registry.mounted.single;
    expect(session.identity.registryEpoch, 1);
    expect(session.identity.instanceId, 'instance-1');
    expect(session.identity.generation, 1);
    expect(session.isActive, isTrue);
    expect(session.hasAction, isTrue);
    expect(session.isObserving, isTrue);
    expect(source.openCount, 1);
    expect(
      session.displayed.value?.formValues['endpoint'],
      'https://local',
    );

    session.dispatch(values: const <String, String>{'endpoint': 'https://next'});
    final invocation = actions.invocations.single;
    expect(invocation.actionRef, 'action:test.save');
    expect(invocation.contributionId, 'vendor.example.form');
    expect(invocation.origin.scope, const ResourceScope('extension:vendor.example.form'));
    expect(invocation.origin.resource, field.resource);
  });

  test('withdrawing an epoch releases its subscriptions and prepared values',
      () async {
    final field = syntheticExtensionField('form-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://local'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.form',
          source: source,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(settingsEpoch(epoch: 1, resourceRef: 'resource:test.form'));
    await pumpEventQueue();
    final session = registry.mounted.single;
    expect(session.displayed.value, isNotNull);

    registry.withdraw();
    await pumpEventQueue();

    expect(registry.mounted, isEmpty);
    expect(registry.snapshot.registryEpoch, 0);
    expect(session.isActive, isFalse);
    expect(session.isObserving, isFalse);
    expect(session.displayed.value, isNull);
    expect(source.closeCount, 1);
  });

  test('a blocked contribution mounts nothing and blocks nothing else',
      () async {
    final field = syntheticExtensionField('plain-resource');
    final source = SyntheticExtensionResourceSource(fieldGroup: field);
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.plain',
          source: source,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    final snapshot = ExtensionUiRegistrySnapshot.fromJson(
      extensionEpochDocument(
        registryEpoch: 2,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.bad',
            kind: 'settings',
            resourceRef: 'resource:test.plain',
            fields: <Map<String, Object?>>[
              extensionFieldJson(
                id: 'key',
                label: 'API key',
                type: 'secret-ref',
                value: 'placeholder-secret',
              ),
            ],
          ),
          extensionContributionJson(
            id: 'vendor.example.plain',
            kind: 'settings',
            resourceRef: 'resource:test.plain',
          ),
        ],
      ),
    );
    registry.mount(snapshot);
    await pumpEventQueue();

    expect(registry.decisions, hasLength(2));
    expect(
      registry.decisions.first.blocked,
      ExtensionUiMountBlock.contributionInvalid,
    );
    expect(registry.mounted, hasLength(1));
    expect(
      registry.mounted.single.contribution.id,
      'vendor.example.plain',
    );
    expect(source.openCount, 1);
  });

  test('a late prepared result after withdrawal never installs', () async {
    final field = syntheticExtensionField('late-resource');
    final gate = Completer<ExtensionUiResourceValue>();
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://local'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.late',
          source: source,
          prepare: (value) => gate.future,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(settingsEpoch(epoch: 3, resourceRef: 'resource:test.late'));
    await pumpEventQueue();
    final session = registry.mounted.single;
    expect(session.displayed.value, isNull, reason: 'preparation is still open');

    registry.withdraw();
    gate.complete(
      ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://late'},
      ),
    );
    await pumpEventQueue();

    expect(session.displayed.value, isNull);
    expect(session.refusedLatePreparations, 1);
    expect(registry.mounted, isEmpty);
  });

  test('an older source position cannot install over a newer one', () async {
    final field = syntheticExtensionField('position-resource');
    final first = Completer<ExtensionUiResourceValue>();
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'first'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.position',
          source: source,
          prepare: (value) => value.formValues['endpoint'] == 'first'
              ? first.future
              : value,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(
      settingsEpoch(epoch: 4, resourceRef: 'resource:test.position'),
    );
    await pumpEventQueue();
    final session = registry.mounted.single;
    expect(session.displayed.value, isNull);

    source.publish(
      ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'second'},
      ),
    );
    await pumpEventQueue();

    first.complete(
      ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'first'},
      ),
    );
    await pumpEventQueue();

    expect(session.displayed.value?.formValues['endpoint'], 'second');
    expect(session.refusedLatePreparations, 1);
  });

  test('an epoch switch releases the removed contribution and leaves an '
      'unrelated consumer source open', () async {
    final firstField = syntheticExtensionField('first-resource');
    final secondField = syntheticExtensionField('second-resource');
    final firstSource = SyntheticExtensionResourceSource(fieldGroup: firstField);
    final secondSource = SyntheticExtensionResourceSource(
      fieldGroup: secondField,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'kept'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.first',
          source: firstSource,
        ),
      )
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.second',
          source: secondSource,
        ),
      );
    // Another feature of the client reads the second resource; the epoch switch
    // must not re-read or close it on that feature's account.
    final otherConsumer = runtime.observe(secondSource);
    final otherSubscription = otherConsumer.stream.listen((_) {});
    addTearDown(otherSubscription.cancel);

    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    final both = ExtensionUiRegistrySnapshot.fromJson(
      extensionEpochDocument(
        registryEpoch: 5,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.first',
            kind: 'settings',
            resourceRef: 'resource:test.first',
          ),
          extensionContributionJson(
            id: 'vendor.example.second',
            kind: 'settings',
            resourceRef: 'resource:test.second',
          ),
        ],
      ),
    );
    registry.mount(both);
    await pumpEventQueue();
    expect(registry.mounted, hasLength(2));
    expect(firstSource.openCount, 1);
    expect(secondSource.openCount, 1);

    final secondOnly = ExtensionUiRegistrySnapshot.fromJson(
      extensionEpochDocument(
        registryEpoch: 6,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.second',
            kind: 'settings',
            resourceRef: 'resource:test.second',
          ),
        ],
      ),
    );
    registry.mount(secondOnly);
    await pumpEventQueue();

    expect(registry.mounted, hasLength(1));
    expect(firstSource.closeCount, 1, reason: 'the removed subscription closed');
    expect(
      secondSource.openCount,
      1,
      reason: 'the still-consumed source was not read again',
    );
    expect(secondSource.closeCount, 0);
    expect(
      registry.mounted.single.displayed.value?.formValues['endpoint'],
      'kept',
      reason: 'the admitted value is replayed without re-reading the source',
    );
  });

  test('mounting the same committed epoch twice is a no-op', () async {
    final field = syntheticExtensionField('stable-resource');
    final source = SyntheticExtensionResourceSource(fieldGroup: field);
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.stable',
          source: source,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    final snapshot = settingsEpoch(epoch: 7, resourceRef: 'resource:test.stable');
    registry.mount(snapshot);
    await pumpEventQueue();
    final session = registry.mounted.single;

    registry.mount(snapshot);
    await pumpEventQueue();

    expect(identical(registry.mounted.single, session), isTrue);
    expect(source.openCount, 1);
    expect(source.closeCount, 0);
  });

  test('authority withdrawal clears the frame and later results cannot install',
      () async {
    final field = syntheticExtensionField('revoked-resource');
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'https://local'},
      ),
    );
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.revoked',
          source: source,
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(settingsEpoch(epoch: 8, resourceRef: 'resource:test.revoked'));
    await pumpEventQueue();
    final session = registry.mounted.single;
    expect(session.displayed.value, isNotNull);

    runtime.revoke(field.resource);
    await pumpEventQueue();

    expect(session.displayed.value, isNull);
    expect(session.localUnavailableReason, 'source_unavailable');
    expect(session.isActive, isTrue, reason: 'only the value was withdrawn');
  });

  test('a newer generation in a new epoch refuses the old generation result',
      () async {
    final field = syntheticExtensionField('generation-resource');
    final gate = Completer<ExtensionUiResourceValue>();
    final source = SyntheticExtensionResourceSource(
      fieldGroup: field,
      initial: ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'first'},
      ),
    );
    var gateUsed = false;
    final bindings = ExtensionUiBindingRegistry()
      ..registerResource(
        ExtensionUiResourceBinding(
          resourceRef: 'resource:test.generation',
          source: source,
          prepare: (value) {
            if (!gateUsed && value.formValues['endpoint'] == 'first') {
              gateUsed = true;
              return gate.future;
            }
            return value;
          },
        ),
      );
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
    );
    addTearDown(registry.dispose);

    registry.mount(
      settingsEpoch(
        epoch: 9,
        resourceRef: 'resource:test.generation',
        generation: 1,
      ),
    );
    await pumpEventQueue();
    final oldSession = registry.mounted.single;

    // The replacement instance's data is published before the new generation
    // mounts, so the new session prepares a newer position of its own.
    source.publish(
      ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'second'},
      ),
    );
    await pumpEventQueue();

    registry.mount(
      settingsEpoch(
        epoch: 10,
        resourceRef: 'resource:test.generation',
        generation: 2,
      ),
    );
    await pumpEventQueue();
    final newSession = registry.mounted.single;
    expect(newSession.identity.generation, 2);
    expect(newSession.isActive, isTrue);

    gate.complete(
      ExtensionUiResourceValue(
        formValues: <String, String>{'endpoint': 'old-generation'},
      ),
    );
    await pumpEventQueue();

    expect(oldSession.isActive, isFalse);
    expect(oldSession.refusedLatePreparations, greaterThanOrEqualTo(1));
    expect(
      newSession.displayed.value?.formValues['endpoint'],
      'second',
      reason: 'the new generation shows its own prepared value',
    );
  });

  test('a missing binding or primitive is local to the contribution', () async {
    final bindings = ExtensionUiBindingRegistry();
    final registry = syntheticExtensionRegistry(
      runtime: runtime,
      bindings: bindings,
      availablePrimitives: const <DeclarativePrimitive>{
        DeclarativePrimitive.form,
      },
    );
    addTearDown(registry.dispose);

    final snapshot = ExtensionUiRegistrySnapshot.fromJson(
      extensionEpochDocument(
        registryEpoch: 11,
        contributions: <Map<String, Object?>>[
          extensionContributionJson(
            id: 'vendor.example.unbound',
            kind: 'settings',
            resourceRef: 'resource:test.missing',
          ),
          extensionContributionJson(
            id: 'vendor.example.command',
            kind: 'command',
          ),
        ],
      ),
    );
    registry.mount(snapshot);
    await pumpEventQueue();

    expect(registry.decisions[0].isMounted, isTrue);
    expect(
      registry.decisions[1].blocked,
      ExtensionUiMountBlock.primitiveUnavailable,
    );
    expect(registry.mounted, hasLength(1));
    final session = registry.mounted.single;
    expect(session.localUnavailableReason, 'binding_unavailable');
    expect(session.isObserving, isFalse);
    expect(session.displayed.value, isNull);
  });
}
