import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/projects/controller/project_controller.dart';
import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';

import 'fixtures/project_gateway_fixture.dart';

ProjectPlanDocument _document({String projectId = 'alpha'}) =>
    ProjectPlanDocument(
      projectId: projectId,
      planId: '$projectId-plan',
      source: const ProjectPlanSourceDeclaration(
        sourceId: 'plan-source',
        sourceKind: 'markdown',
        locator: 'plan/PLAN.md',
      ),
      workItems: <ProjectPlanWorkItemDeclaration>[
        ProjectPlanWorkItemDeclaration(
          workItemId: 'spec',
          outcome: 'Declare the artifact',
          acceptance: const <String>['The reference resolves'],
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

void main() {
  group('project envelope decoding', () {
    test('reads the registered identities of a list envelope', () {
      final wire = projectOkEnvelope(ProjectOperations.list, <String, Object?>{
        'projects': <Object?>[
          projectIdentityWire('alpha', sequence: 1),
          projectIdentityWire('bravo', sequence: 2, displayName: 'Bravo'),
        ],
      });

      final projects = ProjectIdentityFacts.listFromEnvelope(wire);

      expect(projects, hasLength(2));
      final alpha = projects.first;
      expect(alpha.projectId, 'alpha');
      expect(alpha.displayName, 'Project alpha');
      expect(alpha.authorizedRoot, '/srv/roots/alpha');
      expect(alpha.authorizedRootLabel, 'alpha');
      expect(alpha.authorityKind, 'role');
      expect(alpha.authorityReference, 'role:developer');
      expect(alpha.workspaceId, 'alpha-workspace');
      expect(alpha.planId, 'alpha-plan');
      expect(alpha.registrationSequence, 1);
      expect(projects[1].registrationSequence, 2);
      expect(projects[1], isNot(alpha));
    });

    test('reads one identity, and answers null when none is registered', () {
      final present = ProjectIdentityFacts.readFromEnvelope(
        projectOkEnvelope(ProjectOperations.read, <String, Object?>{
          'project': projectIdentityWire('alpha'),
        }),
        projectId: 'alpha',
      );
      final absent = ProjectIdentityFacts.readFromEnvelope(
        projectOkEnvelope(ProjectOperations.read, <String, Object?>{
          'project': null,
        }),
        projectId: 'alpha',
      );

      expect(present?.projectId, 'alpha');
      expect(absent, isNull);
    });

    test('keeps the owner refusal vocabulary of a failed envelope', () {
      final wire = projectFailureEnvelope(
        ProjectOperations.read,
        <String, Object?>{
          'code': 'project_identity_not_registered',
          'stage': 'project_read',
          'retryable': false,
          'recovery': 'declare_identity',
          'presentationArgs': <Object?>['workItems[2].workItemId'],
        },
      );

      expect(
        () => ProjectIdentityFacts.readFromEnvelope(wire, projectId: 'alpha'),
        throwsA(
          isA<ProjectGatewayFailure>()
              .having((f) => f.code, 'code', 'project_identity_not_registered')
              .having((f) => f.stage, 'stage', 'project_read')
              .having((f) => f.retryable, 'retryable', isFalse)
              .having((f) => f.recovery, 'recovery', 'declare_identity')
              .having(
                (f) => f.reference,
                'reference',
                'workItems[2].workItemId',
              )
              .having((f) => f.operation, 'operation', ProjectOperations.read),
        ),
      );
    });

    test('refuses an answer that is not a project envelope', () {
      expect(
        () => ProjectIdentityFacts.listFromEnvelope(<String, Object?>{
          'ok': true,
          'targetIds': <Object?>['codex'],
        }),
        throwsA(
          isA<ProjectGatewayFailure>()
              .having((f) => f.isMalformed, 'isMalformed', isTrue)
              .having((f) => f.code, 'code', projectOperationUnreadable),
        ),
      );
      expect(
        () => ProjectIdentityFacts.listFromEnvelope(null),
        throwsA(isA<ProjectGatewayFailure>()),
      );
    });

    test('reads declared inputs with their explicit artifact state', () {
      final wire = projectOkEnvelope(
        ProjectOperations.dependencies,
        <String, Object?>{
          'projectId': 'alpha',
          'dependencies': <Object?>[
            projectDependencyWire(
              sequence: 1,
              consumerProject: 'alpha',
              consumerItem: 'docs',
              producerProject: 'alpha',
              producerItem: 'spec',
            ),
            projectDependencyWire(
              sequence: 2,
              consumerProject: 'alpha',
              consumerItem: 'docs',
              producerProject: 'bravo',
              producerItem: 'index',
              state: 'missing',
              crossProject: true,
            ),
          ],
        },
      );

      final dependencies = ProjectDependencyFacts.listFromEnvelope(wire);

      expect(dependencies, hasLength(2));
      expect(dependencies.first.dependencySequence, 1);
      expect(dependencies.first.consumer.workItemId, 'docs');
      expect(dependencies.first.producer.workItemId, 'spec');
      expect(
        dependencies.first.artifactState,
        ProjectArtifactState.materialized,
      );
      expect(dependencies.first.isMaterialized, isTrue);
      expect(
        dependencies.first.artifact,
        const ProjectLocalArtifactDeclaration(
          producerWorkItemId: 'spec',
          path: 'artifacts/spec.md',
        ),
      );
      expect(dependencies[1].artifactState, ProjectArtifactState.missing);
      expect(dependencies[1].producer.projectId, 'bravo');
      expect(
        dependencies[1].artifact,
        const ProjectCrossProjectArtifactDeclaration(
          projectId: 'bravo',
          workItemId: 'index',
        ),
      );
    });

    test('reads only the unresolved inputs of the unresolved envelope', () {
      final wire = projectOkEnvelope(
        ProjectOperations.unresolvedArtifacts,
        <String, Object?>{
          'projectId': 'alpha',
          'unresolvedArtifacts': <Object?>[
            projectDependencyWire(
              sequence: 2,
              consumerProject: 'alpha',
              consumerItem: 'docs',
              producerProject: 'alpha',
              producerItem: 'spec',
              state: 'unavailable',
            ),
          ],
        },
      );

      final unresolved = ProjectDependencyFacts.unresolvedFromEnvelope(wire);

      expect(unresolved, hasLength(1));
      expect(unresolved.single.artifactState, ProjectArtifactState.unavailable);
    });

    test('reads the producer and its real dependents', () {
      final wire = projectOkEnvelope(
        ProjectOperations.blockedConsumers,
        <String, Object?>{
          'producer': <String, Object?>{
            'projectId': 'alpha',
            'workItemId': 'spec',
          },
          'blockedConsumers': <Object?>[
            <String, Object?>{'projectId': 'alpha', 'workItemId': 'docs'},
            <String, Object?>{'projectId': 'bravo', 'workItemId': 'index'},
          ],
        },
      );

      final blocked = ProjectBlockedConsumersFacts.fromEnvelope(wire);

      expect(blocked.producer.workItemId, 'spec');
      expect(
        blocked.blockedConsumers.map((consumer) => consumer.workItemId),
        <String>['docs', 'index'],
      );
    });

    test('reads a preview change and an applied outcome', () {
      final preview = ProjectImportChangeFacts.previewFromEnvelope(
        projectOkEnvelope(
          ProjectOperations.importPreview,
          projectChangeWire(retained: const <String>['legacy']),
        ),
      );
      final applied = ProjectImportChangeFacts.appliedFromEnvelope(
        projectOkEnvelope(ProjectOperations.importApply, <String, Object?>{
          'applied': true,
          'change': projectChangeWire(revision: 4),
        }),
      );

      expect(preview.revision, 3);
      expect(preview.digest, 'digest-3');
      expect(preview.replayed, isFalse);
      expect(preview.added, <String>['docs']);
      expect(preview.retained, <String>['legacy']);
      expect(preview.inputCount, 1);
      expect(preview.mapping.single.sourceAnchor, 'Plan#docs');
      expect(applied.applied, isTrue);
      expect(applied.change.revision, 4);
    });
  });

  group('declared plan document', () {
    test('carries only the canonical fields, and no progress field', () {
      final wire = _document().toWire();

      expect(wire.keys.toSet(), <String>{
        'schema',
        'projectId',
        'planId',
        'source',
        'workItems',
      });
      expect(wire['schema'], projectPlanDocumentSchema);
      expect((wire['source']! as Map<String, Object?>).keys.toSet(), <String>{
        'sourceId',
        'sourceKind',
        'locator',
      });
      final items = wire['workItems']! as List<Object?>;
      expect((items.first! as Map<String, Object?>).keys.toSet(), <String>{
        'workItemId',
        'outcome',
        'acceptance',
        'inputs',
        'roles',
        'sourceAnchor',
      });
      final progressFields = <String>{
        'status',
        'state',
        'progress',
        'percentComplete',
        'done',
        'complete',
        'completed',
        'completedAt',
        'finished',
        'finishedAt',
        'startedAt',
        'executed',
        'execution',
        'accepted',
        'acceptanceState',
        'observed',
        'observation',
      };
      for (final item in items) {
        expect(
          (item! as Map<String, Object?>).keys.toSet().intersection(
            progressFields,
          ),
          isEmpty,
        );
      }
    });

    test('serializes the exact canonical document the owner admits', () {
      final wire = _document().toWire();

      expect(wire, <String, Object?>{
        'schema': projectPlanDocumentSchema,
        'projectId': 'alpha',
        'planId': 'alpha-plan',
        'source': <String, Object?>{
          'sourceId': 'plan-source',
          'sourceKind': 'markdown',
          'locator': 'plan/PLAN.md',
        },
        'workItems': <Object?>[
          <String, Object?>{
            'workItemId': 'spec',
            'outcome': 'Declare the artifact',
            'acceptance': <String>['The reference resolves'],
            'inputs': <Object?>[],
            'roles': <Object?>[
              <String, Object?>{
                'roleId': 'editor',
                'scope': 'work-item',
                'capability': null,
              },
            ],
            'sourceAnchor': 'Plan#spec',
          },
          <String, Object?>{
            'workItemId': 'docs',
            'outcome': 'Publish the artifact',
            'acceptance': <String>['The result is materialized'],
            'inputs': <Object?>[
              <String, Object?>{
                'kind': 'local',
                'producerWorkItemId': 'spec',
                'path': 'artifacts/spec.md',
              },
            ],
            'roles': <Object?>[],
            'sourceAnchor': 'Plan#docs',
          },
        ],
      });
    });
  });

  group('ProjectController', () {
    test('loads the registered projects and their dependency facts', () async {
      final gateway = ProjectGatewayFixture(
        projects: ProjectIdentityFacts.listFromEnvelope(
          projectOkEnvelope(ProjectOperations.list, <String, Object?>{
            'projects': <Object?>[projectIdentityWire('alpha')],
          }),
        ),
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
                  state: 'missing',
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
                'unresolvedArtifacts': <Object?>[
                  projectDependencyWire(
                    sequence: 1,
                    consumerProject: 'alpha',
                    consumerItem: 'docs',
                    producerProject: 'alpha',
                    producerItem: 'spec',
                    state: 'missing',
                  ),
                ],
              },
            ),
          ),
        },
      );
      final controller = ProjectController(gateway: gateway);
      addTearDown(controller.dispose);
      final changes = <int>[];
      final subscription = controller.changes.listen((_) => changes.add(1));
      addTearDown(subscription.cancel);

      await controller.loadProjects();

      expect(controller.projects, hasLength(1));
      expect(controller.projects.single.projectId, 'alpha');
      expect(controller.isLoading, isFalse);
      expect(controller.lastFailure, isNull);
      expect(controller.lastErrorCode, '');
      expect(controller.hasDependencyFacts('alpha'), isTrue);
      expect(controller.dependenciesOf('alpha'), hasLength(1));
      expect(controller.unresolvedOf('alpha'), hasLength(1));
      expect(
        controller.dependenciesOf('alpha').single.artifactState,
        ProjectArtifactState.missing,
      );
      expect(gateway.calls, <String>[
        'listProjects',
        'listDependencies:alpha',
        'listUnresolvedArtifacts:alpha',
      ]);
      expect(changes, isNotEmpty);
    });

    test(
      'reports an absent read explicitly for a project never read',
      () async {
        final controller = ProjectController(gateway: ProjectGatewayFixture());
        addTearDown(controller.dispose);

        await controller.loadProjects();

        expect(controller.hasDependencyFacts('alpha'), isFalse);
        expect(controller.dependenciesOf('alpha'), isEmpty);
        expect(controller.declarationOf('alpha'), isNull);
        expect(
          controller.blockedConsumersOf(projectId: 'alpha', workItemId: 'spec'),
          isNull,
        );
      },
    );

    test(
      'records the typed refusal and keeps the facts it already read',
      () async {
        final gateway = ProjectGatewayFixture(
          projects: <ProjectIdentityFacts>[
            ProjectIdentityFacts.fromWire(projectIdentityWire('alpha')),
          ],
        );
        final controller = ProjectController(gateway: gateway);
        addTearDown(controller.dispose);
        await controller.loadProjects();

        gateway.failure = const ProjectGatewayFailure(
          operation: ProjectOperations.dependencies,
          code: 'project_dependency_project_unauthorized',
          stage: 'project_dependency',
          retryable: false,
          recovery: 'declare_identity',
        );
        await controller.loadProjectFacts('alpha');

        expect(
          controller.lastErrorCode,
          'project_dependency_project_unauthorized',
        );
        expect(controller.lastFailure?.stage, 'project_dependency');
        expect(controller.lastFailure?.retryable, isFalse);
        expect(controller.lastFailure?.recovery, 'declare_identity');
        expect(
          controller.projects.single.projectId,
          'alpha',
          reason: 'a refused reread must not discard the facts already read',
        );
      },
    );

    test('reports an unreadable answer as its own refusal code', () async {
      final gateway = ProjectGatewayFixture();
      final controller = ProjectController(gateway: gateway);
      addTearDown(controller.dispose);
      await controller.loadProjects();

      gateway.transportError = StateError('transport closed');
      await controller.loadProjects();

      expect(controller.lastFailure, isNotNull);
      expect(controller.lastFailure!.isMalformed, isTrue);
      expect(controller.lastFailure!.code, projectOperationUnreadable);
      expect(controller.lastErrorCode, projectOperationUnreadable);
    });

    test('reads the real dependents of one blocked producer', () async {
      final gateway = ProjectGatewayFixture(
        blocked: <String, ProjectBlockedConsumersFacts>{
          'alpha/spec': ProjectBlockedConsumersFacts.fromEnvelope(
            projectOkEnvelope(
              ProjectOperations.blockedConsumers,
              <String, Object?>{
                'producer': <String, Object?>{
                  'projectId': 'alpha',
                  'workItemId': 'spec',
                },
                'blockedConsumers': <Object?>[
                  <String, Object?>{
                    'projectId': 'bravo',
                    'workItemId': 'index',
                  },
                ],
              },
            ),
          ),
        },
      );
      final controller = ProjectController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.inspectDependents(
        projectId: 'alpha',
        workItemId: 'spec',
      );

      final blocked = controller.blockedConsumersOf(
        projectId: 'alpha',
        workItemId: 'spec',
      );
      expect(blocked, isNotNull);
      expect(blocked!.blockedConsumers.single.projectId, 'bravo');
      expect(
        controller.blockedConsumersOf(projectId: 'alpha', workItemId: 'docs'),
        isNull,
        reason: 'an unread producer is an explicit absence',
      );
    });

    test('holds a declaration only after the owner admitted it', () async {
      final gateway = ProjectGatewayFixture(
        previewResult: ProjectImportChangeFacts.previewFromEnvelope(
          projectOkEnvelope(
            ProjectOperations.importPreview,
            projectChangeWire(),
          ),
        ),
      );
      final controller = ProjectController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.previewPlan(_document());

      expect(controller.declarationOf('alpha')?.planId, 'alpha-plan');
      final records = controller.importRecordsOf('alpha');
      expect(records, hasLength(1));
      expect(records.single.isPreview, isTrue);
      expect(records.single.change.revision, 3);
      expect(records.single.change.added, <String>['docs']);

      gateway.failure = const ProjectGatewayFailure(
        operation: ProjectOperations.importApply,
        code: 'project_plan_import_stale_apply',
        stage: 'project_plan_import',
        retryable: true,
        recovery: 'preview_again',
      );
      await controller.applyPlan(
        _document(projectId: 'bravo'),
        expectedRevision: 3,
      );

      expect(
        controller.declarationOf('bravo'),
        isNull,
        reason: 'a refused document never becomes the held declaration',
      );
      expect(controller.importRecordsOf('bravo'), isEmpty);
      expect(controller.lastErrorCode, 'project_plan_import_stale_apply');
    });

    test(
      'records an applied receipt and rereads the dependency facts',
      () async {
        final gateway = ProjectGatewayFixture(
          applyResult: ProjectImportChangeFacts.appliedFromEnvelope(
            projectOkEnvelope(ProjectOperations.importApply, <String, Object?>{
              'applied': true,
              'change': projectChangeWire(revision: 4),
            }),
          ),
        );
        final controller = ProjectController(gateway: gateway);
        addTearDown(controller.dispose);

        await controller.applyPlan(_document(), expectedRevision: 3);

        final records = controller.importRecordsOf('alpha');
        expect(records, hasLength(1));
        expect(records.single.isPreview, isFalse);
        expect(records.single.applied, isTrue);
        expect(records.single.change.revision, 4);
        expect(controller.declarationOf('alpha')?.projectId, 'alpha');
        expect(gateway.calls, <String>[
          'applyPlanImport:alpha@3',
          'listDependencies:alpha',
          'listUnresolvedArtifacts:alpha',
        ]);
        expect(controller.hasDependencyFacts('alpha'), isTrue);
      },
    );

    test('a replay is recorded as one effect, not two', () async {
      final gateway = ProjectGatewayFixture(
        applyResult: ProjectImportChangeFacts.appliedFromEnvelope(
          projectOkEnvelope(ProjectOperations.importApply, <String, Object?>{
            'applied': false,
            'change': projectChangeWire(revision: 4, replayed: true),
          }),
        ),
      );
      final controller = ProjectController(gateway: gateway);
      addTearDown(controller.dispose);

      await controller.applyPlan(_document(), expectedRevision: 4);

      final record = controller.importRecordsOf('alpha').single;
      expect(record.applied, isFalse);
      expect(record.change.replayed, isTrue);
    });
  });
}
