import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/appearance/appearance_projection.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/layout/layout_projection.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/agents/agents_resources.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/models/models_providers.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';
import 'package:licoup/src/presentation/search/search_providers.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';
import 'package:licoup/src/presentation/shell/shell_providers.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/presentation/targets/targets_providers.dart';
import 'package:licoup/src/presentation/targets/targets_resources.dart';
import 'package:licoup/src/projections/agents/agents_presentation_source.dart';
import 'package:licoup/src/projections/chrome/chrome_presentation_source.dart';
import 'package:licoup/src/projections/models/models_presentation_source.dart';
import 'package:licoup/src/projections/search/search_presentation_source.dart';
import 'package:licoup/src/projections/shell/shell_presentation_sources.dart';
import 'package:licoup/src/projections/targets/targets_presentation_source.dart';

/// V7-F6A NODE-01: the three new runtime sources plus the seven provider
/// ports. The ports are composition inputs: this suite injects the real
/// adapters, and the counter-examples prove that a missing configuration, a
/// revoked region or a failing source is never masked by the legacy owner
/// value that `binding.projection.current` still returns.
void main() {
  test(
    'chrome source keeps identity and refuses its revoked lineage',
    () async {
      final producer = _FakeSource<ChromeProjection>(_chromeProjection());
      final source = ChromePresentationSource(projection: producer);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final direct = await source.open();
      expect(direct.initial.fieldGroup, chromePresentationFieldGroup);
      expect(direct.initial.value, producer.current);
      final initialPosition = direct.initial.position;
      final changes = <SourceChange<ChromeProjection>>[];
      final subscription = direct.changes.listen(changes.add);
      addTearDown(subscription.cancel);

      producer.publish(_chromeProjection(searchAvailable: true));
      await pumpEventQueue();
      expect(changes, hasLength(1));
      expect(changes.single.base, initialPosition);
      expect(changes.single.group.changed, <ChangedFieldGroup>[
        ChangedFieldGroup.of(chromePresentationFieldGroup),
      ]);

      final observation = runtime.observe(source);
      final lease = runtime.own(source);
      addTearDown(lease.release);
      final visible = <ResourceSnapshot<ChromeProjection>>[];
      final errors = <Object>[];
      final observed = observation.stream.listen(
        visible.add,
        onError: errors.add,
      );
      addTearDown(observed.cancel);
      await _until(() => runtime.current(chromePresentationFieldGroup) != null);
      final visibleBefore = visible.length;

      runtime.revoke(chromePresentationFieldGroup.resource);
      await pumpEventQueue();
      expect(runtime.current(chromePresentationFieldGroup), isNull);
      expect(errors, isNotEmpty);

      producer.publish(_chromeProjection(gatewayRevision: 2));
      await pumpEventQueue();
      expect(runtime.current(chromePresentationFieldGroup), isNull);
      expect(visible, hasLength(visibleBefore));

      await lease.reconnect();
      await _until(() => visible.length > visibleBefore);
      expect(
        runtime
            .current(chromePresentationFieldGroup)
            ?.value
            .gatewayAutoRevealRevision,
        2,
      );
    },
  );

  test(
    'search source keeps identity and releases its upstream subscription',
    () async {
      final producer = _FakeSource<SearchProjection>(_searchProjection());
      final source = SearchPresentationSource(projection: producer);
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);
      final observation = runtime.observe(source);
      final snapshots = <ResourceSnapshot<SearchProjection>>[];
      final observed = observation.stream.listen(snapshots.add);
      addTearDown(observed.cancel);
      await _until(() => runtime.current(searchPresentationFieldGroup) != null);
      expect(producer.listens, 1);

      producer.publish(_searchProjection(query: 'lico'));
      await _until(
        () => snapshots.any((snapshot) => snapshot.value.query == 'lico'),
      );

      await observed.cancel();
      await _until(() => producer.cancels == 1);
      expect(producer.cancels, 1);
    },
  );

  test('shell regions advance in independent field groups', () async {
    final appearance = _FakeSource<AppearanceProjection>(
      _appearanceProjection(),
    );
    final locale = _FakeSource<LocaleProjection>(
      const LocaleProjection('system'),
    );
    final layout = _FakeSource<LayoutProjection>(_layoutProjection());
    final environment = _FakeSource<EnvironmentProjection>(
      _environmentProjection(),
    );
    final navigation = _FakeSource<NavigationProjection>(
      _navigationProjection(),
    );
    final status = _FakeSource<StatusProjection>(_statusProjection());
    final sources = ShellPresentationSources(
      appearance: appearance,
      locale: locale,
      layout: layout,
      environment: environment,
      navigation: navigation,
      status: status,
    );
    addTearDown(sources.dispose);
    final runtime = PresentationRuntime();
    addTearDown(runtime.dispose);

    final appearanceSnapshots = <ResourceSnapshot<AppearanceProjection>>[];
    final statusSnapshots = <ResourceSnapshot<StatusProjection>>[];
    final appearanceObservation = runtime.observe(sources.appearance);
    final statusObservation = runtime.observe(sources.status);
    final appearanceSubscription = appearanceObservation.stream.listen(
      appearanceSnapshots.add,
    );
    final statusSubscription = statusObservation.stream.listen(
      statusSnapshots.add,
    );
    addTearDown(appearanceSubscription.cancel);
    addTearDown(statusSubscription.cancel);
    await _until(
      () =>
          runtime.current(shellAppearancePresentationFields) != null &&
          runtime.current(shellStatusPresentationFields) != null,
    );
    expect(appearanceSnapshots, hasLength(1));
    expect(statusSnapshots, hasLength(1));

    appearance.publish(_appearanceProjection(presetId: 'lico-soda'));
    await _until(() => appearanceSnapshots.length == 2);
    expect(
      statusSnapshots,
      hasLength(1),
      reason: 'an appearance change must not advance the status region',
    );
    expect(
      runtime.current(shellAppearancePresentationFields)?.value.presetId,
      'lico-soda',
    );

    status.publish(_statusProjection(errorCode: 'E-42'));
    await _until(() => statusSnapshots.length == 2);
    expect(appearanceSnapshots, hasLength(2));
    expect(
      runtime.current(shellStatusPresentationFields)?.value.errorCode,
      'E-42',
    );

    final groups = <ResourceFieldGroup<Object?>>[
      shellAppearancePresentationFields,
      shellLocalePresentationFields,
      shellLayoutPresentationFields,
      shellEnvironmentPresentationFields,
      shellNavigationPresentationFields,
      shellStatusPresentationFields,
    ];
    expect(groups.toSet(), hasLength(6));
  });

  test('injected composition source drives the projection provider', () async {
    final producer = _FakeSource<ModelsProjection>(_modelsProjection());
    final container = ProviderContainer(
      overrides: <Override>[
        modelsCatalogSourceProvider.overrideWithValue(
          ModelsPresentationSource(projection: producer),
        ),
      ],
    );
    addTearDown(container.dispose);

    final values = <AsyncValue<ModelsProjection>>[];
    final subscription = container.listen<AsyncValue<ModelsProjection>>(
      modelsCatalogProjectionProvider,
      (_, next) => values.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    expect(values.single.isLoading, isTrue, reason: 'first frame is loading');

    await _until(() => values.last.hasValue);
    expect(values.last.requireValue.phase, PresentationPhase.ready);

    producer.publish(_modelsProjection(phase: PresentationPhase.loading));
    await _until(
      () =>
          values.last.hasValue &&
          values.last.requireValue.phase == PresentationPhase.loading,
    );
  });

  test(
    'unconfigured port errors instead of exposing the owner value',
    () async {
      final producer = _FakeSource<ModelsProjection>(
        _modelsProjection(phase: PresentationPhase.ready),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final values = <AsyncValue<ModelsProjection>>[];
      final subscription = container.listen<AsyncValue<ModelsProjection>>(
        modelsCatalogProjectionProvider,
        (_, next) => values.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _until(() => values.last.hasError);

      // The legacy owner value still exists; the port must never surface it.
      expect(producer.current.phase, PresentationPhase.ready);
      expect(values.last.hasValue, isFalse);
      expect(values.last.error, isA<StateError>());
    },
  );

  test(
    'revoked region stays invisible while the owner value remains',
    () async {
      final producer = _FakeSource<TargetsProjection>(
        _targetsProjection(id: 'first', name: 'First target'),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          targetsCatalogSourceProvider.overrideWithValue(
            TargetsPresentationSource(projection: producer),
          ),
        ],
      );
      addTearDown(container.dispose);

      final values = <AsyncValue<TargetsProjection>>[];
      final subscription = container.listen<AsyncValue<TargetsProjection>>(
        targetsCatalogProjectionProvider,
        (_, next) => values.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _until(() => values.last.hasValue);
      expect(values.last.requireValue.targets.single.id, 'first');

      container
          .read(presentationRuntimeProvider)
          .revoke(targetsCatalogFields.resource);
      await _until(() => values.last.hasError);

      // The owner still holds the target; the revoked region must not show it.
      expect(producer.current.targets.single.id, 'first');
      expect(values.last.hasValue, isFalse);
    },
  );

  test(
    'revoked agents region stays invisible while the owner value remains',
    () async {
      final producer = _FakeSource<AgentsProjection>(
        _agentsProjection(targetDetailId: 'first'),
      );
      final container = ProviderContainer(
        overrides: <Override>[
          agentsCatalogSourceProvider.overrideWithValue(
            AgentsPresentationSource(projection: producer),
          ),
        ],
      );
      addTearDown(container.dispose);

      final values = <AsyncValue<AgentsProjection>>[];
      final subscription = container.listen<AsyncValue<AgentsProjection>>(
        agentsCatalogProjectionProvider,
        (_, next) => values.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await _until(() => values.last.hasValue);
      expect(values.last.requireValue.targetDetails.single.id, 'first');

      container
          .read(presentationRuntimeProvider)
          .revoke(agentsCatalogFields.resource);
      await _until(() => values.last.hasError);

      // The owner still holds the target details the workspace consumes; the
      // revoked region must not surface them.
      expect(producer.current.targetDetails.single.id, 'first');
      expect(values.last.hasValue, isFalse);
    },
  );

  test('injected shell sources drive the six region providers', () async {
    final sources = ShellPresentationSources(
      appearance: _FakeSource<AppearanceProjection>(_appearanceProjection()),
      locale: _FakeSource<LocaleProjection>(const LocaleProjection('system')),
      layout: _FakeSource<LayoutProjection>(_layoutProjection()),
      environment: _FakeSource<EnvironmentProjection>(_environmentProjection()),
      navigation: _FakeSource<NavigationProjection>(_navigationProjection()),
      status: _FakeSource<StatusProjection>(_statusProjection()),
    );
    addTearDown(sources.dispose);
    final container = ProviderContainer(
      overrides: <Override>[
        shellAppearanceSourceProvider.overrideWithValue(sources.appearance),
        shellLocaleSourceProvider.overrideWithValue(sources.locale),
        shellLayoutSourceProvider.overrideWithValue(sources.layout),
        shellEnvironmentSourceProvider.overrideWithValue(sources.environment),
        shellNavigationSourceProvider.overrideWithValue(sources.navigation),
        shellStatusSourceProvider.overrideWithValue(sources.status),
      ],
    );
    addTearDown(container.dispose);

    final appearance = <AsyncValue<AppearanceProjection>>[];
    final navigation = <AsyncValue<NavigationProjection>>[];
    final status = <AsyncValue<StatusProjection>>[];
    final subscriptions = <ProviderSubscription<Object?>>[
      container.listen<AsyncValue<AppearanceProjection>>(
        shellAppearanceProjectionProvider,
        (_, next) => appearance.add(next),
        fireImmediately: true,
      ),
      container.listen<AsyncValue<NavigationProjection>>(
        shellNavigationProjectionProvider,
        (_, next) => navigation.add(next),
        fireImmediately: true,
      ),
      container.listen<AsyncValue<StatusProjection>>(
        shellStatusProjectionProvider,
        (_, next) => status.add(next),
        fireImmediately: true,
      ),
    ];
    addTearDown(() {
      for (final subscription in subscriptions) {
        subscription.close();
      }
    });
    await _until(
      () =>
          appearance.last.hasValue &&
          navigation.last.hasValue &&
          status.last.hasValue,
    );
    expect(appearance.last.requireValue.presetId, isNotEmpty);
    expect(navigation.last.requireValue.destination, ClientSection.agents);
    expect(status.last.requireValue.errorCode, '');
  });

  test('injected search source drives the projection provider', () async {
    final producer = _FakeSource<SearchProjection>(_searchProjection());
    final container = ProviderContainer(
      overrides: <Override>[
        searchSourceProvider.overrideWithValue(
          SearchPresentationSource(projection: producer),
        ),
      ],
    );
    addTearDown(container.dispose);

    final values = <AsyncValue<SearchProjection>>[];
    final subscription = container.listen<AsyncValue<SearchProjection>>(
      searchProjectionProvider,
      (_, next) => values.add(next),
      fireImmediately: true,
    );
    addTearDown(subscription.close);
    await _until(() => values.last.hasValue);
    expect(values.last.requireValue.query, '');

    producer.publish(_searchProjection(query: 'lico'));
    await _until(
      () => values.last.hasValue && values.last.requireValue.query == 'lico',
    );
  });
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 64 && !condition(); attempt += 1) {
    await pumpEventQueue();
  }
  expect(condition(), isTrue, reason: 'condition was not reached in time');
}

ChromeProjection _chromeProjection({
  bool searchAvailable = false,
  int gatewayRevision = 0,
}) => ChromeProjection(
  destinations: const <ChromeDestinationProjection>[],
  notifications: const <PresentationNotice>[],
  auxiliaryPanelOpen: false,
  searchAvailable: searchAvailable,
  gatewayAutoRevealRevision: gatewayRevision,
);

SearchProjection _searchProjection({String query = ''}) => SearchProjection(
  query: query,
  results: const <SearchResultProjection>[],
  open: false,
  phase: PresentationPhase.idle,
);

ModelsProjection _modelsProjection({
  PresentationPhase phase = PresentationPhase.ready,
}) => ModelsProjection(
  providers: const <ModelProviderProjection>[],
  gatewayEnabled: false,
  gatewayStateLabel: '',
  phase: phase,
);

AgentsProjection _agentsProjection({required String targetDetailId}) =>
    AgentsProjection(
      targets: const <AgentTargetProjection>[],
      selectedAgentId: '',
      workingDirectoryLabel: '',
      phase: PresentationPhase.ready,
      targetDetails: <TargetCandidate>[
        TargetCandidate(
          id: targetDetailId,
          target: targetDetailId,
          label: 'Synthetic agent',
          kind: 'agent',
          status: TargetCandidateStatus.detected,
          configured: true,
          confidence: 1,
          adapterStatus: 'ready',
        ),
      ],
    );

TargetsProjection _targetsProjection({
  required String id,
  required String name,
}) => TargetsProjection(
  targets: <TargetProjectionItem>[
    TargetProjectionItem(
      id: id,
      name: name,
      typeLabel: 'CLI',
      readinessLabel: 'ready',
      detail: 'synthetic',
      locationLabel: '/synthetic',
      configured: true,
      pinned: false,
      selected: false,
    ),
  ],
  phase: PresentationPhase.ready,
);

AppearanceProjection _appearanceProjection({String presetId = 'default'}) =>
    AppearanceProjection(
      presetId: presetId,
      presets: const <AppearancePresetProjection>[],
    );

LayoutProjection _layoutProjection() => LayoutProjection(
  LayoutSelectionState(
    committedId: LayoutProfileId.parse('dashboard'),
    effectiveId: LayoutProfileId.parse('dashboard'),
    status: LayoutSelectionStatus.stable,
    surface: LayoutRuntimeSurface.desktop,
    viewport: LayoutViewportClass.expanded,
    operationEpoch: 0,
  ),
);

EnvironmentProjection _environmentProjection() => EnvironmentProjection(
  environment: LayoutEnvironment.fromConstraints(
    surface: LayoutRuntimeSurface.desktop,
    width: 1280,
    height: 800,
    textScale: 1,
  ),
  runtimeSurface: LayoutRuntimeSurface.desktop,
);

NavigationProjection _navigationProjection() => NavigationProjection(
  destination: ClientSection.agents,
  destinations: const <ClientSection>[ClientSection.agents],
);

StatusProjection _statusProjection({String errorCode = ''}) => StatusProjection(
  messageChinese: '',
  messageEnglish: '',
  caption: '',
  errorCode: errorCode,
);

final class _FakeSource<T> implements ProjectionSource<T> {
  _FakeSource(this._current);

  T _current;
  int listens = 0;
  int cancels = 0;
  late final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(
        sync: true,
        onListen: () => listens += 1,
        onCancel: () => cancels += 1,
      );

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value) {
    _current = value;
    _changes.add(ProjectionUpdate<T>(value));
  }
}
