import 'package:licoup/src/contracts/project_management.dart';
import 'package:licoup/src/contracts/project_plan_document.dart';

import 'project_gateway_fixture.dart';

/// One registered project, as `project list` publishes it.
ProjectIdentityFacts projectIdentityFacts(
  String projectId, {
  int sequence = 1,
}) => ProjectIdentityFacts(
  projectId: projectId,
  displayName: 'Project $projectId',
  authorizedRoot: '/srv/roots/$projectId',
  authorityKind: 'role',
  authorityReference: 'role:developer',
  workspaceId: '$projectId-workspace',
  planId: '$projectId-plan',
  registrationSequence: sequence,
);

/// One declared input of [consumerItem], produced by [producerItem].
ProjectDependencyFacts projectDependencyFacts({
  required String consumerProject,
  required String consumerItem,
  required String producerProject,
  required String producerItem,
  String state = 'materialized',
  int sequence = 1,
}) => ProjectDependencyFacts(
  dependencySequence: sequence,
  consumer: ProjectWorkRefFacts(
    projectId: consumerProject,
    workItemId: consumerItem,
  ),
  producer: ProjectWorkRefFacts(
    projectId: producerProject,
    workItemId: producerItem,
  ),
  artifact: ProjectLocalArtifactDeclaration(
    producerWorkItemId: producerItem,
    path: 'artifacts/$producerItem.md',
  ),
  artifactState: ProjectArtifactState.fromWire(state)!,
);

/// The canonical document a caller converted for one project.
ProjectPlanDocument projectPlanDocument({String projectId = 'alpha'}) =>
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
          workItemId: 'docs',
          outcome: 'Publish the artifact',
          acceptance: const <String>['The artifact is materialized'],
          inputs: const <ProjectArtifactDeclaration>[
            ProjectLocalArtifactDeclaration(
              producerWorkItemId: 'spec',
              path: 'artifacts/spec.md',
            ),
          ],
          sourceAnchor: 'Plan#docs',
        ),
      ],
    );

/// The change a preview of [projectPlanDocument] reports.
ProjectImportChangeFacts projectImportChangeFacts({
  String projectId = 'alpha',
  int revision = 3,
  List<String> added = const <String>['docs'],
  List<String> retained = const <String>['spec'],
}) => ProjectImportChangeFacts(
  projectId: projectId,
  planId: '$projectId-plan',
  sourceId: 'plan-source',
  revision: revision,
  digest: 'digest-$revision',
  replayed: false,
  added: added,
  retained: retained,
  mapping: <ProjectSourceMappingFacts>[
    const ProjectSourceMappingFacts(
      workItemId: 'docs',
      sourceId: 'plan-source',
      sourceAnchor: 'Plan#docs',
    ),
  ],
  inputCount: 1,
);

/// Two registered projects, one declared dependency each, and the blocked
/// consumers `alpha/docs` actually has.
ProjectGatewayFixture twoProjectGateway({
  ProjectImportChangeFacts? previewResult,
  ProjectPlanImportOutcomeFacts? applyResult,
}) => ProjectGatewayFixture(
  projects: <ProjectIdentityFacts>[
    projectIdentityFacts('alpha'),
    projectIdentityFacts('beta', sequence: 2),
  ],
  dependencies: <String, List<ProjectDependencyFacts>>{
    'alpha': <ProjectDependencyFacts>[
      projectDependencyFacts(
        consumerProject: 'alpha',
        consumerItem: 'docs',
        producerProject: 'alpha',
        producerItem: 'spec',
      ),
    ],
    'beta': <ProjectDependencyFacts>[
      projectDependencyFacts(
        consumerProject: 'beta',
        consumerItem: 'report',
        producerProject: 'beta',
        producerItem: 'data',
        state: 'missing',
      ),
    ],
  },
  unresolved: <String, List<ProjectDependencyFacts>>{
    'beta': <ProjectDependencyFacts>[
      projectDependencyFacts(
        consumerProject: 'beta',
        consumerItem: 'report',
        producerProject: 'beta',
        producerItem: 'data',
        state: 'missing',
      ),
    ],
  },
  blocked: <String, ProjectBlockedConsumersFacts>{
    'alpha/docs': ProjectBlockedConsumersFacts(
      producer: const ProjectWorkRefFacts(
        projectId: 'alpha',
        workItemId: 'docs',
      ),
      blockedConsumers: const <ProjectWorkRefFacts>[
        ProjectWorkRefFacts(projectId: 'alpha', workItemId: 'release'),
      ],
    ),
  },
  previewResult: previewResult,
  applyResult: applyResult,
);

/// How many recorded calls start with [prefix].
int projectCallsWithPrefix(List<String> calls, String prefix) =>
    calls.where((call) => call.startsWith(prefix)).length;
