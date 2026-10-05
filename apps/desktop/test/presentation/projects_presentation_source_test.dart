import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/projects/projects_effect.dart';
import 'package:licoup/src/presentation/projects/projects_intent.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/presentation/projects/projects_resources.dart';
import 'package:licoup/src/presentation/projects/projects_view.dart';
import 'package:licoup/src/projections/projects/projects_effect_producer.dart';
import 'package:licoup/src/projections/projects/projects_layout_presentation_source.dart';
import 'package:licoup/src/projections/projects/projects_presentation_source.dart';

ProjectsProjection _projection({
  PresentationPhase phase = PresentationPhase.ready,
  String outcome = 'Publish the artifact',
}) => ProjectsProjection(
  projects: <ProjectCardProjection>[
    ProjectCardProjection(
      projectId: 'alpha',
      displayName: 'Alpha',
      authorizedRoot: '/srv/roots/alpha',
      authorityKind: 'role',
      authorityReference: 'role:developer',
      workspaceId: 'alpha-workspace',
      planId: 'alpha-plan',
      registrationSequence: 1,
      workItems: <ProjectWorkItemFacts>[
        ProjectWorkItemFacts(
          projectId: 'alpha',
          workItemId: 'docs',
          declarationState: ProjectDeclarationState.held,
          durableMembership: ProjectDurableMembership.added,
          declaredOutcome: outcome,
          declaredAcceptance: const <String>['The result is materialized'],
          sourceAnchor: 'Plan#docs',
          inputs:
              ProjectDeclaredInputsFacts.observed(<ProjectDeclaredInputFacts>[
                ProjectDeclaredInputFacts(
                  producer: const ProjectWorkRefFacts(
                    projectId: 'alpha',
                    workItemId: 'spec',
                  ),
                  artifact: const ProjectLocalArtifactDeclaration(
                    producerWorkItemId: 'spec',
                    path: 'artifacts/spec.md',
                  ),
                  state: ProjectInputState.missing,
                  dependencySequence: 1,
                ),
              ]),
          dependents: const ProjectDependentsFacts.notObserved(),
        ),
      ],
    ),
  ],
  phase: phase,
);

void main() {
  group('ProjectsPresentationSource', () {
    test('opens with the initial snapshot and resource identity', () async {
      final producer = _FakeProjectionSource<ProjectsProjection>(_projection());
      final source = ProjectsPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, projectsCatalogFields);
      expect(source.fieldGroup.resource, projectsCatalogResource);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.fieldGroup, projectsCatalogFields);
      expect(initial.resource, projectsCatalogResource);
      expect(initial.version.value, 1);
      expect(initial.value, producer.current);
      expect(initial.consistencyGroup, isNotNull);
      expect(initial.consistencyGroup!.affects(projectsCatalogFields), isTrue);
      expect(
        initial.consistencyGroup!.affects(projectsLayoutFields),
        isFalse,
        reason: 'a facts snapshot cannot claim the local arrangement',
      );
    });

    test('publishes base-matched changes with monotonic versions', () async {
      final producer = _FakeProjectionSource<ProjectsProjection>(_projection());
      final source = ProjectsPresentationSource(projection: producer);
      addTearDown(source.dispose);
      final observation = await source.open();
      final published = <SourceChange<ProjectsProjection>>[];
      final subscription = observation.changes.listen(published.add);
      addTearDown(subscription.cancel);

      final next = _projection(phase: PresentationPhase.failed);
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
      expect(change.group.affects(projectsCatalogFields), isTrue);
      expect(
        change.group.position.compare(observation.initial.position),
        VersionRelation.newer,
      );
    });

    test(
      'reopen keeps version continuity without dropping interim facts',
      () async {
        final producer = _FakeProjectionSource<ProjectsProjection>(
          _projection(),
        );
        final source = ProjectsPresentationSource(projection: producer);
        addTearDown(source.dispose);

        final first = await source.open();
        final firstSubscription = first.changes.listen((_) {});
        producer.publish(_projection(phase: PresentationPhase.loading));
        await firstSubscription.cancel();
        await pumpEventQueue();

        producer.publish(_projection(phase: PresentationPhase.failed));
        final second = await source.open();
        expect(second.initial.value.phase, PresentationPhase.failed);
        expect(second.initial.position.isAfter(first.initial.position), isTrue);
        expect(second.initial.epoch, first.initial.epoch);
      },
    );

    test('exposes a provider entry bound to the catalog resource', () {
      final source = ProjectsPresentationSource(
        projection: _FakeProjectionSource<ProjectsProjection>(_projection()),
      );
      addTearDown(source.dispose);

      expect(presentationProviderEntry(source).resource, projectsCatalogFields);
    });
  });

  group('ProjectsLayoutPresentationSource', () {
    test('opens with the arrangement and its own resource identity', () async {
      final layout = ProjectsLayoutState().moved(
        projectId: 'alpha',
        workItemId: 'docs',
        x: 12,
        y: 34,
      );
      final producer = _FakeProjectionSource<ProjectsLayoutState>(layout);
      final source = ProjectsLayoutPresentationSource(projection: producer);
      addTearDown(source.dispose);

      expect(source.fieldGroup, projectsLayoutFields);
      final observation = await source.open();
      final initial = observation.initial;
      expect(initial.resource, projectsLayoutResource);
      expect(initial.value, layout);
      expect(initial.consistencyGroup!.affects(projectsLayoutFields), isTrue);
      expect(initial.consistencyGroup!.affects(projectsCatalogFields), isFalse);
    });

    test('a drag publishes a layout change and no facts change', () async {
      final factsProducer = _FakeProjectionSource<ProjectsProjection>(
        _projection(),
      );
      final factsSource = ProjectsPresentationSource(projection: factsProducer);
      addTearDown(factsSource.dispose);
      final layoutProducer = _FakeProjectionSource<ProjectsLayoutState>(
        ProjectsLayoutState(),
      );
      final layoutSource = ProjectsLayoutPresentationSource(
        projection: layoutProducer,
      );
      addTearDown(layoutSource.dispose);

      final factsObservation = await factsSource.open();
      final layoutObservation = await layoutSource.open();
      final factsChanges = <SourceChange<ProjectsProjection>>[];
      final layoutChanges = <SourceChange<ProjectsLayoutState>>[];
      final factsSubscription = factsObservation.changes.listen(
        factsChanges.add,
      );
      final layoutSubscription = layoutObservation.changes.listen(
        layoutChanges.add,
      );
      addTearDown(factsSubscription.cancel);
      addTearDown(layoutSubscription.cancel);

      layoutProducer.publish(
        layoutProducer.current.moved(
          projectId: 'alpha',
          workItemId: 'docs',
          x: 480,
          y: 96,
        ),
      );

      expect(factsChanges, isEmpty, reason: 'a drag is not a facts change');
      expect(layoutChanges, hasLength(1));
      expect(layoutChanges.single.group.affects(projectsLayoutFields), isTrue);
      expect(
        layoutChanges.single.group.affects(projectsCatalogFields),
        isFalse,
      );
      expect(
        layoutChanges.single.snapshot.value.placementOf('alpha/docs')?.x,
        480,
      );
      expect(
        factsSource.fieldGroup,
        projectsCatalogFields,
        reason: 'the facts resource keeps its identity across a drag',
      );
    });

    test('installs both resources through one runtime', () async {
      final runtime = PresentationRuntime();
      addTearDown(runtime.dispose);

      final factsSource = ProjectsPresentationSource(
        projection: _FakeProjectionSource<ProjectsProjection>(_projection()),
      );
      addTearDown(factsSource.dispose);
      final layoutSource = ProjectsLayoutPresentationSource(
        projection: _FakeProjectionSource<ProjectsLayoutState>(
          ProjectsLayoutState(),
        ),
      );
      addTearDown(layoutSource.dispose);

      final factsObservation = runtime.observe(factsSource);
      final layoutObservation = runtime.observe(layoutSource);
      final factsSubscription = factsObservation.snapshots.listen((_) {});
      final layoutSubscription = layoutObservation.snapshots.listen((_) {});
      addTearDown(factsSubscription.cancel);
      addTearDown(layoutSubscription.cancel);
      await pumpEventQueue();

      expect(runtime.current(projectsCatalogFields), isNotNull);
      expect(runtime.current(projectsLayoutFields), isNotNull);
      expect(
        runtime.current(projectsCatalogFields)!.resource,
        projectsCatalogResource,
      );
    });
  });

  group('ProjectsEffectProducer', () {
    test('publishes one-shot results and closes deterministically', () async {
      final producer = ProjectsEffectProducer();
      final published = <ProjectsEffect>[];
      final subscription = producer.effects.listen(published.add);
      addTearDown(subscription.cancel);

      producer.emit(
        const ProjectPlanPreviewed(
          projectId: 'alpha',
          planId: 'alpha-plan',
          revision: 3,
          replayed: false,
          addedCount: 2,
          unchangedCount: 0,
          retainedCount: 1,
        ),
      );
      producer.emit(
        const ProjectRequestRejected(
          operation: ProjectOperations.dependencies,
          reasonCode: 'project_dependency_project_unauthorized',
          stage: 'project_dependency',
          retryable: false,
          recovery: 'declare_identity',
          reference: 'workItems[2].workItemId',
        ),
      );
      await pumpEventQueue();

      expect(published, hasLength(2));
      final previewed = published.first as ProjectPlanPreviewed;
      expect(previewed.revision, 3);
      expect(previewed.retainedCount, 1);
      final rejected = published.last as ProjectRequestRejected;
      expect(rejected.reasonCode, 'project_dependency_project_unauthorized');
      expect(rejected.reference, 'workItems[2].workItemId');
      expect(rejected.retryable, isFalse);

      await producer.dispose();
      expect(producer.isClosed, isTrue);
      producer.emit(
        const ProjectPlanApplied(
          projectId: 'alpha',
          planId: 'alpha-plan',
          revision: 4,
          applied: true,
        ),
      );
      await pumpEventQueue();
      expect(
        published,
        hasLength(2),
        reason: 'a closed lane drops late effects',
      );
    });
  });

  group('ProjectsActions', () {
    test('dispatch typed intents with the pinned project origin', () async {
      final intents = _RecordingProjectIntents();
      final actions = ProjectsActions.fromIntents(intents);
      final document = ProjectPlanDocument(
        projectId: 'alpha',
        planId: 'alpha-plan',
        source: const ProjectPlanSourceDeclaration(
          sourceId: 'plan-source',
          sourceKind: 'markdown',
          locator: 'plan/PLAN.md',
        ),
        workItems: <ProjectPlanWorkItemDeclaration>[
          ProjectPlanWorkItemDeclaration(
            workItemId: 'docs',
            outcome: 'Publish the artifact',
          ),
        ],
      );

      expect(actions.origin.scope, projectsPresentationScope);
      expect(actions.origin.resource, projectsCatalogResource);

      await actions.refresh();
      await actions.loadFacts('alpha');
      await actions.inspectDependents(projectId: 'alpha', workItemId: 'spec');
      await actions.previewImport(document);
      await actions.applyImport(document, expectedRevision: 3);

      expect(intents.values, hasLength(5));
      expect(intents.values[0], isA<RefreshProjects>());
      expect((intents.values[1] as LoadProjectFacts).projectId, 'alpha');
      final dependents = intents.values[2] as InspectProjectDependents;
      expect(dependents.workItemId, 'spec');
      expect((intents.values[3] as PreviewProjectPlan).document, document);
      final apply = intents.values[4] as ApplyProjectPlan;
      expect(apply.expectedRevision, 3);
      expect(apply.document, document);
    });

    test('a drag is a local action and never a durable intent', () async {
      final mutations = _RecordingLayoutMutations();
      final actions = ProjectLayoutActions.fromMutations(mutations);

      expect(actions.origin.scope, projectsPresentationScope);
      expect(actions.origin.resource, projectsLayoutResource);

      actions.moveCard(projectId: 'alpha', workItemId: 'docs', x: 480, y: 96);
      actions.reorder(<String>['alpha/docs', 'alpha/spec']);

      expect(mutations.moves, hasLength(1));
      expect(mutations.moves.single, <String, Object?>{
        'projectId': 'alpha',
        'workItemId': 'docs',
        'x': 480.0,
        'y': 96.0,
      });
      expect(mutations.orders, <List<String>>[
        <String>['alpha/docs', 'alpha/spec'],
      ]);

      const move = MoveProjectCard(
        projectId: 'alpha',
        workItemId: 'docs',
        x: 1,
        y: 2,
      );
      expect(
        move,
        isNot(isA<ProjectsIntent>()),
        reason:
            'the local action hierarchy shares no member with the durable '
            'intent hierarchy',
      );
      expect(
        ReorderProjectList(const <String>['alpha/docs']),
        isNot(isA<ProjectsIntent>()),
      );
    });
  });
}

final class _FakeProjectionSource<T> implements ProjectionSource<T> {
  _FakeProjectionSource(this._current);

  T _current;
  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void publish(T value, {TraceContext? trace}) {
    _current = value;
    _changes.add(ProjectionUpdate<T>(value, trace: trace));
  }
}

final class _RecordingProjectIntents implements IntentSink<ProjectsIntent> {
  final List<ProjectsIntent> values = <ProjectsIntent>[];

  @override
  void send(ProjectsIntent intent) => values.add(intent);
}

final class _RecordingLayoutMutations implements ProjectLayoutMutations {
  final List<Map<String, Object?>> moves = <Map<String, Object?>>[];
  final List<List<String>> orders = <List<String>>[];

  @override
  void moveCard({
    required String projectId,
    required String workItemId,
    required double x,
    required double y,
  }) => moves.add(<String, Object?>{
    'projectId': projectId,
    'workItemId': workItemId,
    'x': x,
    'y': y,
  });

  @override
  void reorder(Iterable<String> keys) =>
      orders.add(List<String>.unmodifiable(keys));
}
