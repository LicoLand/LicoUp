import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/application/features/projects/controller/project_controller.dart';
import 'package:licoup/src/application/features/projects/controller/project_layout_controller.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/projects/projects_binding.dart';
import 'package:licoup/src/presentation/projects/projects_intent.dart';
import 'package:licoup/src/presentation/projects/projects_layout.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';
import 'package:licoup/src/presentation/projects/projects_resources.dart';
import 'package:licoup/src/presentation/projects/projects_view.dart';
import 'package:licoup/src/projections/projects/projects_effect_producer.dart';
import 'package:licoup/src/projections/projects/projects_layout_presentation_source.dart';
import 'package:licoup/src/projections/projects/projects_layout_projection_producer.dart';
import 'package:licoup/src/projections/projects/projects_presentation_source.dart';
import 'package:licoup/src/projections/projects/projects_projection_producer.dart';

import 'fixtures/project_gateway_fixture.dart';

/// The plan declaration this client holds for `alpha`.
ProjectPlanDocument _alphaPlan() => ProjectPlanDocument(
  projectId: 'alpha',
  planId: 'alpha-plan',
  source: const ProjectPlanSourceDeclaration(
    sourceId: 'plan-source',
    sourceKind: 'markdown',
    locator: 'plan/PLAN.md',
  ),
  workItems: <ProjectPlanWorkItemDeclaration>[
    ProjectPlanWorkItemDeclaration(
      workItemId: 'spec',
      outcome: 'Declare the artifact',
      acceptance: const <String>['The reference resolves to a declared path'],
      roles: const <ProjectRoleDeclaration>[
        ProjectRoleDeclaration(
          roleId: 'editor',
          scope: ProjectRoleScope.workItem,
        ),
      ],
      sourceAnchor: 'Plan#spec',
    ),
    ProjectPlanWorkItemDeclaration(
      workItemId: 'docs',
      outcome: 'Publish the artifact',
      acceptance: const <String>['The result is materialized'],
      inputs: <ProjectArtifactDeclaration>[
        ProjectArtifactDeclaration.local(
          producerWorkItemId: 'spec',
          path: 'artifacts/spec.md',
        ),
      ],
      sourceAnchor: 'Plan#docs',
    ),
  ],
);

ProjectGatewayFixture _gateway({
  String docsArtifactState = 'missing',
  List<String> appliedAdded = const <String>['spec', 'docs'],
  List<String> appliedRetained = const <String>['legacy'],
}) => ProjectGatewayFixture(
  projects: <ProjectIdentityFacts>[
    ProjectIdentityFacts.fromWire(projectIdentityWire('alpha', sequence: 1)),
    ProjectIdentityFacts.fromWire(projectIdentityWire('bravo', sequence: 2)),
  ],
  dependencies: <String, List<ProjectDependencyFacts>>{
    'alpha': ProjectDependencyFacts.listFromEnvelope(
      projectOkEnvelope(ProjectOperations.dependencies, <String, Object?>{
        'projectId': 'alpha',
        'dependencies': <Object?>[
          projectDependencyWire(
            sequence: 1,
            consumerProject: 'alpha',
            consumerItem: 'docs',
            producerProject: 'alpha',
            producerItem: 'spec',
            state: docsArtifactState,
          ),
        ],
      }),
    ),
    'bravo': ProjectDependencyFacts.listFromEnvelope(
      projectOkEnvelope(ProjectOperations.dependencies, <String, Object?>{
        'projectId': 'bravo',
        'dependencies': <Object?>[
          projectDependencyWire(
            sequence: 1,
            consumerProject: 'bravo',
            consumerItem: 'index',
            producerProject: 'alpha',
            producerItem: 'docs',
            crossProject: true,
          ),
        ],
      }),
    ),
  },
  unresolved: <String, List<ProjectDependencyFacts>>{
    'alpha': ProjectDependencyFacts.unresolvedFromEnvelope(
      projectOkEnvelope(
        ProjectOperations.unresolvedArtifacts,
        <String, Object?>{
          'projectId': 'alpha',
          'unresolvedArtifacts': docsArtifactState == 'materialized'
              ? <Object?>[]
              : <Object?>[
                  projectDependencyWire(
                    sequence: 1,
                    consumerProject: 'alpha',
                    consumerItem: 'docs',
                    producerProject: 'alpha',
                    producerItem: 'spec',
                    state: docsArtifactState,
                  ),
                ],
        },
      ),
    ),
    'bravo': const <ProjectDependencyFacts>[],
  },
  blocked: <String, ProjectBlockedConsumersFacts>{
    // The owner reports the transitive closure, across projects.
    'alpha/spec': ProjectBlockedConsumersFacts.fromEnvelope(
      projectOkEnvelope(ProjectOperations.blockedConsumers, <String, Object?>{
        'producer': <String, Object?>{
          'projectId': 'alpha',
          'workItemId': 'spec',
        },
        'blockedConsumers': <Object?>[
          <String, Object?>{'projectId': 'alpha', 'workItemId': 'docs'},
          <String, Object?>{'projectId': 'bravo', 'workItemId': 'index'},
        ],
      }),
    ),
  },
  previewResult: ProjectImportChangeFacts.previewFromEnvelope(
    projectOkEnvelope(
      ProjectOperations.importPreview,
      projectChangeWire(added: appliedAdded, retained: appliedRetained),
    ),
  ),
  applyResult: ProjectImportChangeFacts.appliedFromEnvelope(
    projectOkEnvelope(ProjectOperations.importApply, <String, Object?>{
      'applied': true,
      'change': projectChangeWire(
        added: appliedAdded,
        retained: appliedRetained,
      ),
    }),
  ),
);

/// One project surface: the durable facts, the local arrangement and the two
/// presentation shapes both views are built from.
final class _ProjectSurface {
  _ProjectSurface({required this.gateway})
    : controller = ProjectController(gateway: gateway),
      layout = ProjectLayoutController() {
    facts = ProjectsProjectionProducer(controller: controller);
    layoutFacts = ProjectsLayoutProjectionProducer(controller: layout);
  }

  final ProjectGatewayFixture gateway;
  final ProjectController controller;
  final ProjectLayoutController layout;
  late final ProjectsProjectionProducer facts;
  late final ProjectsLayoutProjectionProducer layoutFacts;

  ProjectsProjection get projection => facts.current;

  ProjectsListViewInputs viewFor(String projectId) =>
      ProjectsListViewInputs.fromProjection(
        projection: projection,
        layout: layout.layout,
        projectId: projectId,
      );

  ProjectsCanvasViewInputs graphFor(String projectId) =>
      ProjectsCanvasViewInputs.fromProjection(
        projection: projection,
        layout: layout.layout,
        projectId: projectId,
      );

  /// Loads the projects, the dependency facts, and applies the held
  /// declaration, so every fact source this surface reads is observed.
  Future<void> load() async {
    await controller.loadProjects();
    await controller.applyPlan(_alphaPlan(), expectedRevision: 3);
  }

  Future<void> dispose() async {
    await facts.dispose();
    await layoutFacts.dispose();
    controller.dispose();
    layout.dispose();
  }
}

ProjectWorkItemFacts _factsOf(
  Iterable<ProjectWorkItemFacts> facts,
  String id,
) => facts.firstWhere((item) => item.workItemId == id);

void main() {
  group('project views', () {
    test('the list and the graph read the identical fact list', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();

      final list = surface.viewFor('alpha');
      final graph = surface.graphFor('alpha');

      expect(list.projectId, 'alpha');
      expect(graph.projectId, 'alpha');
      expect(list.card, graph.card);
      expect(
        identical(list.facts, graph.facts),
        isTrue,
        reason:
            'one fact list is shared; a view adds order and coordinates '
            'only',
      );
      expect(list.rows, hasLength(graph.nodes.length));

      final nodesByKey = <String, ProjectCanvasNodeInputs>{
        for (final node in graph.nodes) node.key: node,
      };
      for (final row in list.rows) {
        final node = nodesByKey[row.key];
        expect(node, isNotNull, reason: row.key);
        expect(identical(row.facts, node!.facts), isTrue);
        expect(row.facts.blockingReason, node.facts.blockingReason);
        expect(row.facts.isBlocked, node.facts.isBlocked);
        expect(row.facts.inputs, node.facts.inputs);
        expect(row.facts.dependents, node.facts.dependents);
        expect(row.facts.declaredOutcome, node.facts.declaredOutcome);
        expect(row.facts.declaredAcceptance, node.facts.declaredAcceptance);
        expect(row.facts.declarationState, node.facts.declarationState);
        expect(row.facts.durableMembership, node.facts.durableMembership);
        expect(row.facts.sourceAnchor, node.facts.sourceAnchor);
      }
      expect(list.phase, graph.phase);
      expect(list.phase, PresentationPhase.ready);
      expect(list.notice, isNull);
    });

    test('no view invents a run, a completion or an acceptance', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();

      final list = surface.viewFor('alpha');

      expect(list.facts, isNotEmpty);
      for (final item in list.facts) {
        expect(item.run, ProjectRuntimeObservation.notObserved);
        expect(item.completion, ProjectRuntimeObservation.notObserved);
        expect(item.acceptance, ProjectRuntimeObservation.notObserved);
      }
      final alpha = surface.projection.project('alpha')!;
      expect(alpha.workItems, isNotEmpty);
      expect(
        alpha.workItems.map((item) => item.run).toSet(),
        <ProjectRuntimeObservation>{ProjectRuntimeObservation.notObserved},
      );
      expect(
        alpha.workItems.map((item) => item.completion).toSet(),
        <ProjectRuntimeObservation>{ProjectRuntimeObservation.notObserved},
      );
      expect(
        alpha.workItems.map((item) => item.acceptance).toSet(),
        <ProjectRuntimeObservation>{ProjectRuntimeObservation.notObserved},
      );
    });

    test(
      'both views identify the same blocked item and real dependents',
      () async {
        final surface = _ProjectSurface(gateway: _gateway());
        addTearDown(surface.dispose);
        await surface.load();
        await surface.controller.inspectDependents(
          projectId: 'alpha',
          workItemId: 'spec',
        );

        final list = surface.viewFor('alpha');
        final graph = surface.graphFor('alpha');
        final listDocs = _factsOf(list.facts, 'docs');
        final graphDocs = _factsOf(graph.facts, 'docs');

        expect(listDocs.blockingReason, ProjectBlockingReason.missingArtifact);
        expect(graphDocs.blockingReason, ProjectBlockingReason.missingArtifact);
        expect(listDocs.isBlocked, isTrue);
        expect(graphDocs.isBlocked, isTrue);
        expect(listDocs.inputs.observed, isTrue);
        final input = listDocs.inputs.unsatisfied.single;
        expect(input.state, ProjectInputState.missing);
        expect(input.artifactLabel, 'artifacts/spec.md');
        expect(input.producer.projectId, 'alpha');
        expect(input.producer.workItemId, 'spec');
        expect(input.dependencySequence, 1);
        expect(graphDocs.inputs.unsatisfied.single, input);

        final listSpec = _factsOf(list.facts, 'spec');
        final graphSpec = _factsOf(graph.facts, 'spec');
        expect(listSpec.dependents.observed, isTrue);
        expect(listSpec.dependents.dependents, <ProjectWorkRefFacts>[
          const ProjectWorkRefFacts(projectId: 'alpha', workItemId: 'docs'),
          const ProjectWorkRefFacts(projectId: 'bravo', workItemId: 'index'),
        ]);
        expect(graphSpec.dependents, listSpec.dependents);
        expect(
          graph.nodes.firstWhere((node) => node.workItemId == 'spec').outgoing,
          listSpec.dependents.dependents,
        );
        expect(listSpec.blockingReason, ProjectBlockingReason.none);
      },
    );

    test('an observed empty answer differs from an unread one', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();
      await surface.controller.inspectDependents(
        projectId: 'bravo',
        workItemId: 'index',
      );

      final bravo = surface.viewFor('bravo');
      final index = _factsOf(bravo.facts, 'index');
      expect(index.dependents.observed, isTrue);
      expect(index.dependents.dependents, isEmpty);
      expect(
        index.dependents,
        isNot(const ProjectDependentsFacts.notObserved()),
      );

      final alpha = surface.viewFor('alpha');
      final docs = _factsOf(alpha.facts, 'docs');
      expect(docs.dependents.observed, isFalse);
      expect(docs.dependents, const ProjectDependentsFacts.notObserved());
      expect(
        index.dependents,
        isNot(docs.dependents),
        reason: 'blocks nobody is not the same as never read',
      );
    });

    test('a drag changes the local layout and nothing durable', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();
      final intents = _RecordingProjectIntents();
      final durableActions = ProjectsActions.fromIntents(intents);
      final layoutSource = ProjectsLayoutPresentationSource(
        projection: surface.layoutFacts,
      );
      addTearDown(layoutSource.dispose);
      final observation = await layoutSource.open();
      final published = <SourceChange<ProjectsLayoutState>>[];
      final subscription = observation.changes.listen(published.add);
      addTearDown(subscription.cancel);

      final factsBefore = surface.projection;
      final callsBefore = surface.gateway.callCount;
      final orderBefore = surface
          .viewFor('alpha')
          .rows
          .map((row) => row.key)
          .toList();

      ProjectLayoutActions.fromMutations(
        surface.layout,
      ).moveCard(projectId: 'alpha', workItemId: 'docs', x: 512, y: 128);

      expect(surface.layout.layout.placementOf('alpha/docs')?.x, 512);
      expect(surface.layout.layout.placementOf('alpha/docs')?.y, 128);
      expect(
        surface.gateway.callCount,
        callsBefore,
        reason: 'a drag reaches no durable read or write',
      );
      expect(intents.values, isEmpty);
      expect(surface.projection, factsBefore);
      expect(published, hasLength(1));
      expect(published.single.group.affects(projectsLayoutFields), isTrue);
      expect(published.single.group.affects(projectsCatalogFields), isFalse);
      expect(durableActions.origin.resource, projectsCatalogResource);

      final graph = surface.graphFor('alpha');
      final node = graph.nodes.firstWhere((item) => item.workItemId == 'docs');
      expect(node.placement.x, 512);
      expect(node.placement.y, 128);
      expect(node.placement.movedByUser, isTrue);
      expect(
        surface.viewFor('alpha').rows.map((row) => row.key).toList(),
        orderBefore,
        reason: 'moving a card is not reordering the list',
      );
      expect(
        _factsOf(graph.facts, 'docs').blockingReason,
        ProjectBlockingReason.missingArtifact,
      );
    });

    test('a reorder changes the local list order and no fact', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();
      final factsBefore = surface.projection;
      final callsBefore = surface.gateway.callCount;
      final orderBefore = surface
          .viewFor('alpha')
          .rows
          .map((row) => row.key)
          .toList();
      expect(orderBefore, <String>['alpha/spec', 'alpha/docs', 'alpha/legacy']);

      ProjectLayoutActions.fromMutations(
        surface.layout,
      ).reorder(<String>['alpha/docs', 'alpha/spec']);

      expect(
        surface.viewFor('alpha').rows.map((row) => row.key).toList(),
        <String>['alpha/docs', 'alpha/spec', 'alpha/legacy'],
        reason: 'keys the reorder does not name keep their canonical place',
      );
      expect(surface.viewFor('alpha').rows.first.position, 0);
      expect(
        surface.viewFor('alpha').rows.map((row) => row.facts.declaredOutcome),
        <String>['Publish the artifact', 'Declare the artifact', ''],
        reason: 'only the local order changed, never the facts a row shows',
      );
      expect(surface.projection, factsBefore);
      expect(surface.gateway.callCount, callsBefore);
    });

    test('a facts refresh after a drag preserves task state', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();
      ProjectLayoutActions.fromMutations(
        surface.layout,
      ).moveCard(projectId: 'alpha', workItemId: 'docs', x: 512, y: 128);
      final before = surface.projection;
      final specBefore = _factsOf(surface.viewFor('alpha').facts, 'spec');
      final docsBefore = _factsOf(surface.viewFor('alpha').facts, 'docs');

      await surface.controller.loadProjectFacts('alpha');

      expect(
        surface.projection,
        before,
        reason: 'a reread that observes the same facts is one value',
      );
      expect(_factsOf(surface.viewFor('alpha').facts, 'spec'), specBefore);
      expect(_factsOf(surface.viewFor('alpha').facts, 'docs'), docsBefore);
      final graph = surface.graphFor('alpha');
      expect(
        graph.nodes.firstWhere((node) => node.workItemId == 'docs').placement.x,
        512,
        reason: 'the refresh does not reset the local arrangement',
      );
      expect(
        graph.nodes.firstWhere((node) => node.workItemId == 'docs').placement.y,
        128,
      );
      expect(
        _factsOf(graph.facts, 'docs').declaredOutcome,
        'Publish the artifact',
      );
      expect(_factsOf(graph.facts, 'docs').declaredAcceptance, <String>[
        'The result is materialized',
      ]);
    });

    test(
      'a durable change reaches both views while the drag stays local',
      () async {
        final gateway = _gateway();
        final surface = _ProjectSurface(gateway: gateway);
        addTearDown(surface.dispose);
        await surface.load();
        ProjectLayoutActions.fromMutations(
          surface.layout,
        ).moveCard(projectId: 'alpha', workItemId: 'docs', x: 512, y: 128);
        final before = surface.projection;
        expect(
          _factsOf(surface.viewFor('alpha').facts, 'docs').blockingReason,
          ProjectBlockingReason.missingArtifact,
        );

        final materialized = _gateway(docsArtifactState: 'materialized');
        gateway.dependencies = materialized.dependencies;
        gateway.unresolved = materialized.unresolved;
        await surface.controller.loadProjectFacts('alpha');

        final list = surface.viewFor('alpha');
        final graph = surface.graphFor('alpha');
        expect(surface.projection, isNot(before));
        expect(list.facts, graph.facts);
        expect(
          _factsOf(list.facts, 'docs').blockingReason,
          ProjectBlockingReason.none,
        );
        expect(
          _factsOf(graph.facts, 'docs').blockingReason,
          ProjectBlockingReason.none,
        );
        expect(
          _factsOf(list.facts, 'spec').declaredOutcome,
          'Declare the artifact',
          reason: 'a changed input state does not rewrite a declaration',
        );
        expect(
          _factsOf(list.facts, 'spec').dependents,
          const ProjectDependentsFacts.notObserved(),
        );
        expect(
          graph.nodes
              .firstWhere((node) => node.workItemId == 'docs')
              .placement
              .x,
          512,
        );
        expect(list.rows.map((row) => row.key).toList(), <String>[
          'alpha/spec',
          'alpha/docs',
          'alpha/legacy',
        ]);
      },
    );

    test('an unread dependency set reports blocking as not observed', () async {
      final gateway = _gateway()
        ..refusedCallPrefix = 'listDependencies:alpha'
        ..transportError = StateError('dependency read unavailable');
      final surface = _ProjectSurface(gateway: gateway);
      addTearDown(surface.dispose);

      await surface.controller.loadProjects();
      await surface.controller.previewPlan(_alphaPlan());

      final list = surface.viewFor('alpha');
      final docs = _factsOf(list.facts, 'docs');
      expect(docs.declarationState, ProjectDeclarationState.held);
      expect(docs.inputs.observed, isFalse);
      expect(docs.inputs.inputs, isEmpty);
      expect(docs.blockingReason, ProjectBlockingReason.notObserved);
      expect(docs.isBlocked, isFalse);
      expect(list.facts, surface.graphFor('alpha').facts);
    });

    test(
      'an unreachable declared location is its own blocking reason',
      () async {
        final surface = _ProjectSurface(
          gateway: _gateway(docsArtifactState: 'unavailable'),
        );
        addTearDown(surface.dispose);
        await surface.load();

        final docs = _factsOf(surface.viewFor('alpha').facts, 'docs');

        expect(docs.inputs.inputs.single.state, ProjectInputState.unavailable);
        expect(docs.blockingReason, ProjectBlockingReason.unavailableArtifact);
        expect(
          _factsOf(surface.graphFor('alpha').facts, 'docs').blockingReason,
          ProjectBlockingReason.unavailableArtifact,
        );
      },
    );

    test(
      'a retained work item keeps its durable facts and reports the absence',
      () async {
        final surface = _ProjectSurface(gateway: _gateway());
        addTearDown(surface.dispose);
        await surface.load();

        final legacy = _factsOf(surface.viewFor('alpha').facts, 'legacy');

        expect(legacy.durableMembership, ProjectDurableMembership.retained);
        expect(legacy.declarationState, ProjectDeclarationState.notHeld);
        expect(legacy.declaredOutcome, '');
        expect(legacy.declaredAcceptance, isEmpty);
        expect(legacy.sourceAnchor, '');
        expect(legacy.inputs.observed, isTrue);
        expect(legacy.inputs.inputs, isEmpty);
        expect(legacy.blockingReason, ProjectBlockingReason.none);
        expect(legacy.run, ProjectRuntimeObservation.notObserved);
      },
    );

    test(
      'an input no apply stored keeps its reference and an explicit state',
      () async {
        final gateway = _gateway()
          ..dependencies = <String, List<ProjectDependencyFacts>>{
            'alpha': const <ProjectDependencyFacts>[],
          }
          ..unresolved = <String, List<ProjectDependencyFacts>>{
            'alpha': const <ProjectDependencyFacts>[],
          };
        final surface = _ProjectSurface(gateway: gateway);
        addTearDown(surface.dispose);

        await surface.controller.loadProjects();
        await surface.controller.previewPlan(_alphaPlan());

        final docs = _factsOf(surface.viewFor('alpha').facts, 'docs');
        expect(docs.declarationState, ProjectDeclarationState.held);
        expect(
          docs.durableMembership,
          ProjectDurableMembership.notObserved,
          reason: 'a preview changes nothing, so it stores no membership',
        );
        final input = docs.inputs.inputs.single;
        expect(input.state, ProjectInputState.notApplied);
        expect(input.dependencySequence, isNull);
        expect(input.artifactLabel, 'artifacts/spec.md');
        expect(input.producer.workItemId, 'spec');
        expect(docs.blockingReason, ProjectBlockingReason.unappliedInput);
        expect(docs.isBlocked, isTrue);
      },
    );

    test(
      'a refused read is explicit and preserves the facts already read',
      () async {
        final surface = _ProjectSurface(gateway: _gateway());
        addTearDown(surface.dispose);
        await surface.load();
        final before = surface.projection;

        surface.gateway.failure = const ProjectGatewayFailure(
          operation: ProjectOperations.dependencies,
          code: 'project_dependency_project_unauthorized',
          stage: 'project_dependency',
          retryable: false,
          recovery: 'declare_identity',
        );
        await surface.controller.loadProjectFacts('alpha');

        final after = surface.projection;
        expect(after.phase, PresentationPhase.failed);
        expect(after.failureCode, 'project_dependency_project_unauthorized');
        expect(after.notice, isNotNull);
        expect(
          after.notice!.reasonCode,
          'project_dependency_project_unauthorized',
        );
        expect(after.notice!.recovery, 'declare_identity');
        expect(after.notice!.severity, PresentationNoticeSeverity.error);
        expect(
          after.projects.first.workItems,
          before.projects.first.workItems,
          reason: 'the facts read before the refusal are preserved',
        );
        expect(surface.viewFor('alpha').phase, PresentationPhase.failed);
        expect(surface.graphFor('alpha').phase, PresentationPhase.failed);
      },
    );

    test('a view switch never changes a fact', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();
      final facts = surface.viewFor('alpha').facts;

      final graph = surface.graphFor('alpha');
      ProjectLayoutActions.fromMutations(
        surface.layout,
      ).moveCard(projectId: 'alpha', workItemId: 'spec', x: 40, y: 40);
      ProjectLayoutActions.fromMutations(
        surface.layout,
      ).reorder(<String>['alpha/legacy']);

      expect(surface.viewFor('alpha').facts, facts);
      expect(graph.facts, facts);
      expect(identical(graph.facts, facts), isTrue);
      expect(surface.viewFor('alpha').phase, graph.phase);
      expect(surface.viewFor('alpha').card, graph.card);
    });
  });

  group('project binding', () {
    test('a drag through the binding reaches the local sink only', () async {
      final surface = _ProjectSurface(gateway: _gateway());
      addTearDown(surface.dispose);
      await surface.load();
      final intents = _RecordingProjectIntents();
      final effects = ProjectsEffectProducer();
      addTearDown(effects.dispose);
      final factsSource = ProjectsPresentationSource(projection: surface.facts);
      addTearDown(factsSource.dispose);
      final layoutSource = ProjectsLayoutPresentationSource(
        projection: surface.layoutFacts,
      );
      addTearDown(layoutSource.dispose);
      final binding = ProjectsBinding(
        projection: surface.facts,
        layout: surface.layoutFacts,
        intents: intents,
        layoutMutations: surface.layout,
        effects: effects,
      );

      expect(binding.projection.current, surface.projection);
      expect(binding.layout.current, surface.layout.layout);
      expect(
        presentationProviderEntry(factsSource).resource,
        projectsCatalogFields,
      );
      expect(
        presentationProviderEntry(layoutSource).resource,
        projectsLayoutFields,
      );
      expect(layoutSource.fieldGroup, projectsLayoutFields);
      expect(factsSource.fieldGroup, projectsCatalogFields);

      final factsBefore = surface.projection;
      final callsBefore = surface.gateway.callCount;
      binding.layoutMutations.moveCard(
        projectId: 'alpha',
        workItemId: 'spec',
        x: 64,
        y: 32,
      );

      expect(binding.layout.current.placementOf('alpha/spec')?.x, 64);
      expect(
        binding.projection.current,
        factsBefore,
        reason: 'the arrangement lane cannot rewrite the facts lane',
      );
      expect(surface.gateway.callCount, callsBefore);
      expect(intents.values, isEmpty);
    });
  });

  group('local layout boundary', () {
    test('the arrangement cannot name a durable command type', () {
      final layout = File(
        'lib/src/presentation/projects/projects_layout.dart',
      ).readAsStringSync();
      expect(layout, isNot(contains('project_management')));
      expect(layout, isNot(contains('/application/')));
      expect(layout, isNot(contains('/platform/')));
      expect(layout, isNot(contains('/projections/')));

      final owner = File(
        'lib/src/application/features/projects/controller/'
        'project_layout_controller.dart',
      ).readAsStringSync();
      expect(owner, isNot(contains('ProjectManagementGateway')));
      expect(owner, isNot(contains('project_management')));
      expect(owner, isNot(contains('/platform/')));

      final intents = File(
        'lib/src/presentation/projects/projects_intent.dart',
      ).readAsStringSync();
      expect(
        intents,
        isNot(contains('double')),
        reason: 'no durable intent can carry a coordinate',
      );
    });

    test('the durable controller exposes no arrangement verb', () {
      final controller = File(
        'lib/src/application/features/projects/controller/'
        'project_controller.dart',
      ).readAsStringSync();
      expect(controller, isNot(contains('ProjectLayoutMutations')));
      expect(controller, isNot(contains('ProjectsLayoutState')));
    });
  });
}

final class _RecordingProjectIntents implements IntentSink<ProjectsIntent> {
  final List<ProjectsIntent> values = <ProjectsIntent>[];

  @override
  void send(ProjectsIntent intent) => values.add(intent);
}
