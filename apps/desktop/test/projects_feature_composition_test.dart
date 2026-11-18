import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/features/projects/projects_feature_composition.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/presentation/projects/projects_intent.dart';
import 'package:licoup/src/presentation/projects/projects_projection.dart';

import 'fixtures/project_gateway_fixture.dart';
import 'fixtures/project_surface_fixture.dart';

/// The commands one intent produced, in the order the owner answered them.
List<String> _since(ProjectGatewayFixture gateway, int mark) =>
    gateway.calls.sublist(mark);

void main() {
  test('one preview intent reaches the project owner exactly once', () async {
    final gateway = twoProjectGateway(
      previewResult: projectImportChangeFacts(),
    );
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);

    composition.binding.intents.send(PreviewProjectPlan(projectPlanDocument()));
    await pumpEventQueue();

    expect(gateway.calls, const <String>['previewPlanImport:alpha']);
    expect(projectCallsWithPrefix(gateway.calls, 'previewPlanImport'), 1);
    expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);
    expect(gateway.submitted.single.projectId, 'alpha');
  });

  test(
    'a preview declares the change and inserts nothing before confirmation',
    () async {
      final gateway = twoProjectGateway(
        previewResult: projectImportChangeFacts(),
        applyResult: ProjectPlanImportOutcomeFacts(
          applied: true,
          change: projectImportChangeFacts(),
        ),
      );
      final composition = ProjectsFeatureComposition(gateway);
      addTearDown(composition.dispose);

      composition.binding.intents.send(const RefreshProjects());
      await pumpEventQueue();
      final mark = gateway.callCount;

      composition.binding.intents.send(
        PreviewProjectPlan(projectPlanDocument()),
      );
      await pumpEventQueue();

      expect(_since(gateway, mark), const <String>['previewPlanImport:alpha']);
      expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);
      final previewed = composition.binding.projection.current.project(
        'alpha',
      )!;
      expect(
        previewed.importReceipts.single.kind,
        ProjectImportReceiptKind.previewed,
      );
      expect(previewed.importReceipts.single.applied, isFalse);
      expect(previewed.importReceipts.single.revision, 3);
      final declared = previewed.workItem('docs')!;
      expect(declared.declarationState, ProjectDeclarationState.held);
      expect(
        declared.durableMembership,
        ProjectDurableMembership.notObserved,
        reason: 'a preview changes no durable membership',
      );
      expect(declared.run, ProjectRuntimeObservation.notObserved);

      // The confirmation the surface renders shows these facts: what the
      // change names and which work items it affects. Only the confirmed
      // insert reaches the owner, once, over the previewed revision.
      composition.binding.intents.send(
        ApplyProjectPlan(projectPlanDocument(), expectedRevision: 3),
      );
      await pumpEventQueue();

      expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 1);
      expect(gateway.calls, contains('applyPlanImport:alpha@3'));
      final applied = composition.binding.projection.current.project('alpha')!;
      expect(
        applied.importReceipts.last.kind,
        ProjectImportReceiptKind.applied,
      );
      expect(applied.importReceipts.last.applied, isTrue);
      expect(
        applied.workItem('docs')!.durableMembership,
        ProjectDurableMembership.added,
      );
      expect(
        applied.workItem('docs')!.run,
        ProjectRuntimeObservation.notObserved,
        reason: 'an applied declaration is still not a run',
      );
      expect(
        applied.workItem('docs')!.acceptance,
        ProjectRuntimeObservation.notObserved,
      );
    },
  );

  test('one insert intent reaches the project owner exactly once', () async {
    final gateway = twoProjectGateway(
      applyResult: ProjectPlanImportOutcomeFacts(
        applied: true,
        change: projectImportChangeFacts(),
      ),
    );
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);

    composition.binding.intents.send(
      ApplyProjectPlan(projectPlanDocument(), expectedRevision: 3),
    );
    await pumpEventQueue();

    expect(gateway.calls, const <String>[
      'applyPlanImport:alpha@3',
      // The apply changed durable state, so its owner re-reads the facts of
      // the project it changed. Those two calls are reads; a second insert
      // would be a duplicate command and there is none.
      'listDependencies:alpha',
      'listUnresolvedArtifacts:alpha',
    ]);
    expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 1);
    expect(projectCallsWithPrefix(gateway.calls, 'previewPlanImport'), 0);
  });

  test(
    'one affected-consumer read reaches the project owner exactly once',
    () async {
      final gateway = twoProjectGateway();
      final composition = ProjectsFeatureComposition(gateway);
      addTearDown(composition.dispose);

      composition.binding.intents.send(
        const InspectProjectDependents(projectId: 'alpha', workItemId: 'docs'),
      );
      await pumpEventQueue();

      expect(gateway.calls, const <String>['listBlockedConsumers:alpha/docs']);
    },
  );

  test('moving a card sends no command and changes no fact', () async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);

    composition.binding.intents.send(const RefreshProjects());
    await pumpEventQueue();
    final factsBefore = composition.binding.projection.current;
    final mark = gateway.callCount;

    composition.binding.layoutMutations.moveCard(
      projectId: 'alpha',
      workItemId: 'docs',
      x: 120,
      y: 64,
    );
    await pumpEventQueue();

    expect(_since(gateway, mark), isEmpty);
    expect(
      composition.binding.layout.current.placementOf('alpha/docs')?.movedByUser,
      isTrue,
    );
    expect(
      composition.binding.layout.current.placementOf('alpha/docs')?.x,
      120,
    );
    expect(
      composition.binding.projection.current,
      same(factsBefore),
      reason: 'a drag republishes no durable fact',
    );
    expect(
      composition.binding.projection.current
          .project('alpha')!
          .workItem('docs')!
          .run,
      ProjectRuntimeObservation.notObserved,
    );
  });

  test(
    'reading a project surface starts nothing and accepts nothing',
    () async {
      final gateway = twoProjectGateway();
      final composition = ProjectsFeatureComposition(gateway);
      addTearDown(composition.dispose);

      composition.binding.intents.send(const RefreshProjects());
      await pumpEventQueue();
      // Everything a view switch reads: both resources, in the order a renderer
      // reads them.
      final projection = composition.binding.projection.current;
      final layout = composition.binding.layout.current;
      final mark = gateway.callCount;
      await pumpEventQueue();

      expect(_since(gateway, mark), isEmpty);
      expect(gateway.submitted, isEmpty);
      expect(projectCallsWithPrefix(gateway.calls, 'applyPlanImport'), 0);
      expect(projectCallsWithPrefix(gateway.calls, 'previewPlanImport'), 0);
      final facts = projection.project('alpha')!.workItem('docs')!;
      expect(facts.run, ProjectRuntimeObservation.notObserved);
      expect(facts.completion, ProjectRuntimeObservation.notObserved);
      expect(facts.acceptance, ProjectRuntimeObservation.notObserved);
      expect(layout.canvasPlacements, isEmpty);
    },
  );

  test('an action on one project never names another', () async {
    final gateway = twoProjectGateway();
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);

    composition.binding.intents.send(const RefreshProjects());
    await pumpEventQueue();
    final betaBefore = composition.binding.projection.current.project('beta')!;
    final alpha = composition.binding.projection.current
        .project('alpha')!
        .workItem('docs')!;
    final mark = gateway.callCount;

    composition.binding.intents.send(
      InspectProjectDependents(
        projectId: alpha.projectId,
        workItemId: alpha.workItemId,
      ),
    );
    await pumpEventQueue();

    final issued = _since(gateway, mark);
    expect(issued, const <String>['listBlockedConsumers:alpha/docs']);
    expect(
      issued.where((call) => call.contains('beta')),
      isEmpty,
      reason: 'an intent scoped to alpha must not reach beta',
    );
    expect(gateway.submitted, isEmpty);
    final betaAfter = composition.binding.projection.current.project('beta')!;
    expect(betaAfter, betaBefore, reason: 'beta facts are unchanged');
    expect(
      composition.binding.projection.current
          .project('alpha')!
          .workItem('docs')!
          .dependents
          .dependents,
      const <ProjectWorkRefFacts>[
        ProjectWorkRefFacts(projectId: 'alpha', workItemId: 'release'),
      ],
    );
  });

  test('a refused read is reported with the owner vocabulary', () async {
    final gateway = twoProjectGateway();
    gateway.failure = const ProjectGatewayFailure(
      operation: ProjectOperations.dependencies,
      code: 'project_not_found',
      stage: 'authorization',
      recovery: 'register',
    );
    final composition = ProjectsFeatureComposition(gateway);
    addTearDown(composition.dispose);

    composition.binding.intents.send(const RefreshProjects());
    await pumpEventQueue();

    expect(gateway.calls.first, 'listProjects');
    final projection = composition.binding.projection.current;
    expect(projection.failureCode, 'project_not_found');
    expect(projection.notice?.recovery, 'register');
  });

  test(
    'an unbound client refuses instead of reporting an empty catalog',
    () async {
      final composition = ProjectsFeatureComposition(
        const UnboundProjectManagementGateway(),
      );
      addTearDown(composition.dispose);

      composition.binding.intents.send(const RefreshProjects());
      await pumpEventQueue();

      final projection = composition.binding.projection.current;
      expect(projection.projects, isEmpty);
      expect(projection.failureCode, unboundProjectManagementCode);
      expect(projection.notice, isNotNull);
    },
  );
}
