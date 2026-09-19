import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_resources.dart';
import 'package:licoup/src/presentation/models/models_view.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/models/models_presentation_source.dart';

void main() {
  ModelsProjection projection({
    PresentationPhase phase = PresentationPhase.ready,
    String gatewayStateLabel = 'stopped',
  }) => ModelsProjection(
    providers: const [],
    gatewayEnabled: false,
    gatewayStateLabel: gatewayStateLabel,
    phase: phase,
  );

  group('ModelsPresentationSource', () {
    test('opens with the initial snapshot and resource identity', () async {
      final producer = _FakeModelsProjectionSource(projection());
      final source = ModelsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, modelsCatalogFields);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.fieldGroup, modelsCatalogFields);
      expect(initial.resource, modelsCatalogResource);
      expect(initial.version.value, 1);
      expect(initial.value, producer.current);
      expect(initial.consistencyGroup, isNotNull);
      expect(initial.consistencyGroup!.affects(modelsCatalogFields), isTrue);
    });

    test(
      'publishes base-matched changes with monotonic versions and trace',
      () async {
        final producer = _FakeModelsProjectionSource(projection());
        final source = ModelsPresentationSource(projection: producer);
        addTearDown(source.dispose);
        final observation = await source.open();
        final published = <SourceChange<ModelsProjection>>[];
        final subscription = observation.changes.listen(published.add);
        addTearDown(subscription.cancel);

        final next = projection(phase: PresentationPhase.loading);
        const trace = TraceContext(traceId: 'trace-1');
        producer.publish(next, trace: trace);
        producer.publish(next);

        expect(published, hasLength(1));
        final change = published.single;
        expect(change.base, observation.initial.position);
        expect(change.position.version.value, 2);
        expect(change.snapshot.value, next);
        expect(change.trace, trace);
        expect(change.hasValidGroup, isTrue);
        expect(change.group.affects(modelsCatalogFields), isTrue);
        expect(
          change.group.position.compare(observation.initial.position),
          VersionRelation.newer,
        );
      },
    );

    test(
      'reopen keeps version continuity without dropping interim facts',
      () async {
        final producer = _FakeModelsProjectionSource(projection());
        final source = ModelsPresentationSource(projection: producer);
        addTearDown(source.dispose);

        final first = await source.open();
        final firstSubscription = first.changes.listen((_) {});
        producer.publish(projection(phase: PresentationPhase.loading));
        await firstSubscription.cancel();
        await pumpEventQueue();

        producer.publish(projection(phase: PresentationPhase.failed));
        final second = await source.open();
        expect(second.initial.value.phase, PresentationPhase.failed);
        expect(second.initial.position.isAfter(first.initial.position), isTrue);
        expect(second.initial.epoch, first.initial.epoch);
      },
    );

    test('installs snapshots through the shared runtime observation', () async {
      final producer = _FakeModelsProjectionSource(projection());
      final source = ModelsPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final states = <ResourceSnapshot<ModelsProjection>>[];
      final observation = runtime.observe(source);
      final subscription = observation.snapshots.listen(states.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(states, hasLength(1));
      expect(states.single.value, producer.current);
      expect(states.single.fieldGroup, modelsCatalogFields);

      producer.publish(projection(phase: PresentationPhase.loading));
      await pumpEventQueue();

      expect(states, hasLength(2));
      expect(states[1].value.phase, PresentationPhase.loading);
      expect(states[1].position.isAfter(states[0].position), isTrue);
      expect(states[1].consistencyGroup!.affects(modelsCatalogFields), isTrue);
      expect(
        runtime.current(modelsCatalogFields)?.value.phase,
        PresentationPhase.loading,
      );
    });

    test('exposes a provider entry bound to the catalog resource', () {
      final producer = _FakeModelsProjectionSource(projection());
      final source = ModelsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      final entry = presentationProviderEntry(source);
      expect(entry.resource, modelsCatalogFields);
    });
  });

  group('ModelsCatalogActions', () {
    test('dispatch typed intents with the pinned models origin', () async {
      final intents = _RecordingModelsIntents();
      final actions = ModelsCatalogActions.fromIntents(intents);

      expect(actions.origin.scope, modelsPresentationScope);
      expect(actions.origin.resource, modelsCatalogResource);

      await actions.refreshModels();
      await actions.refreshGateway();
      await actions.setGatewayEnabled(true);
      await actions.saveGatewayEndpoint('http://127.0.0.1:15722');
      await actions.selectGatewayModel('openai', 'gpt-5');
      await actions.authorizeModelProvider('openai');
      await actions.recoverGateway();
      await actions.refreshGatewayCredentials();
      await actions.migrateGatewayCredentials();
      await actions.createGatewayCredential(
        provider: 'openai',
        label: 'work',
        apiKey: 'test-api-key',
        leaseDays: 7,
      );
      await actions.updateGatewayCredential(
        'credential-1',
        label: 'renamed',
        extendDays: 3,
      );
      await actions.deleteGatewayCredential('credential-1');
      await actions.setGatewayCredentialAuthorized('credential-1', false);
      await actions.authorizeAllGatewayCredentials();
      await actions.refreshTelegramChannel();
      await actions.saveTelegramToken('test-telegram-token');
      await actions.clearTelegramToken();
      await actions.approveTelegramPairing('abcd1234');
      await actions.revokeTelegramChat(42);

      expect(intents.values, hasLength(19));
      expect(intents.values[0], isA<RefreshModels>());
      expect(intents.values[1], isA<RefreshGateway>());
      expect((intents.values[2] as SetGatewayEnabled).enabled, isTrue);
      expect(
        (intents.values[3] as SaveGatewayEndpoint).endpoint,
        'http://127.0.0.1:15722',
      );
      final select = intents.values[4] as SelectGatewayModel;
      expect(select.providerId, 'openai');
      expect(select.modelId, 'gpt-5');
      expect(
        (intents.values[5] as AuthorizeModelProvider).providerId,
        'openai',
      );
      expect(intents.values[6], isA<RecoverModelGateway>());
      expect(intents.values[7], isA<RefreshGatewayCredentials>());
      expect(intents.values[8], isA<MigrateGatewayCredentials>());
      final create = intents.values[9] as CreateGatewayCredential;
      expect(create.provider, 'openai');
      expect(create.label, 'work');
      expect(create.apiKey, 'test-api-key');
      expect(create.leaseDays, 7);
      final update = intents.values[10] as UpdateGatewayCredential;
      expect(update.credentialId, 'credential-1');
      expect(update.label, 'renamed');
      expect(update.extendDays, 3);
      expect(
        (intents.values[11] as DeleteGatewayCredential).credentialId,
        'credential-1',
      );
      final authorized = intents.values[12] as SetGatewayCredentialAuthorized;
      expect(authorized.credentialId, 'credential-1');
      expect(authorized.authorized, isFalse);
      expect(intents.values[13], isA<AuthorizeAllGatewayCredentials>());
      expect(intents.values[14], isA<RefreshTelegramChannel>());
      expect(
        (intents.values[15] as SaveTelegramToken).token,
        'test-telegram-token',
      );
      expect(intents.values[16], isA<ClearTelegramToken>());
      expect((intents.values[17] as ApproveTelegramPairing).code, 'abcd1234');
      expect((intents.values[18] as RevokeTelegramChat).chatId, 42);
    });

    test('inputs map the catalog projection without losing fields', () {
      final value = projection(phase: PresentationPhase.failed);
      final inputs = ModelsCatalogInputs.fromProjection(value);

      expect(inputs.scope, modelsPresentationScope);
      expect(inputs.phase, value.phase);
      expect(inputs.gateway, value.gateway);
      expect(inputs.credentials, value.credentials);
      expect(
        inputs.credentialMigrationPending,
        value.credentialMigrationPending,
      );
      expect(inputs.telegram, value.telegram);
      expect(inputs.notice, value.notice);

      final equal = ModelsCatalogInputs.fromProjection(value);
      expect(inputs, equal);
      expect(inputs.hashCode, equal.hashCode);
      expect(
        inputs,
        isNot(
          ModelsCatalogInputs.fromProjection(
            projection(phase: PresentationPhase.loading),
          ),
        ),
      );
    });
  });
}

final class _FakeModelsProjectionSource
    implements ProjectionSource<ModelsProjection> {
  _FakeModelsProjectionSource(this._current);

  ModelsProjection _current;
  final StreamController<ProjectionUpdate<ModelsProjection>> _changes =
      StreamController<ProjectionUpdate<ModelsProjection>>.broadcast(
        sync: true,
      );

  @override
  ModelsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<ModelsProjection>> get changes => _changes.stream;

  void publish(ModelsProjection value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate<ModelsProjection>(value, trace: trace));
  }
}

final class _RecordingModelsIntents implements IntentSink<ModelsIntent> {
  final List<ModelsIntent> values = <ModelsIntent>[];

  @override
  void send(ModelsIntent intent) => values.add(intent);
}
