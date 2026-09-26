/// Synthetic project collaboration scenarios and a synthetic action owner.
///
/// The documents here are the real `licoup.ui.graph-resource.v1` shape, so the
/// interface is exercised against the published contract. The synthetic owner
/// stands in only where the native producer will sit: it is injected
/// explicitly, never compiled into a product path, and it answers with the same
/// receipt fields the native owner must.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/project_collaboration/project_collaboration_surface.dart';

/// Builds one document with the given revision and node statuses.
///
/// Node statuses are addressed by identity so a test can move one unit without
/// restating the document.
Map<String, Object?> documentJson({
  required int planRevision,
  required List<String> nodeIds,
  Map<String, String> execution = const <String, String>{},
  Map<String, String> acceptance = const <String, String>{},
  Map<String, String> observation = const <String, String>{},
  Map<String, bool> ready = const <String, bool>{},
  Map<String, bool> startable = const <String, bool>{},
  Map<String, List<Map<String, Object?>>> blockers =
      const <String, List<Map<String, Object?>>>{},
  String? gateId = 'licoup.gate/alpha-accept',
  List<String> gateAnchors = const <String>[],
  int runCount = 4,
  String projectId = 'licoup.project/alpha',
  String projectTitle = 'Alpha',
  List<Map<String, Object?>> extraProjects = const <Map<String, Object?>>[],
  List<Map<String, Object?>> edges = const <Map<String, Object?>>[],
}) => <String, Object?>{
  'schema': graphResourceV1Schema,
  'revision': planRevision,
  'projects': <Object?>[
    <String, Object?>{
      'id': projectId,
      'title': projectTitle,
      'lanes': <Object?>[
        <String, Object?>{
          'id': 'licoup.lane/build',
          'title': 'Build',
          'order': 0,
        },
        <String, Object?>{
          'id': 'licoup.lane/review',
          'title': 'Review',
          'order': 1,
        },
      ],
      'nodes': <Object?>[
        for (final id in nodeIds)
          <String, Object?>{
            'id': id,
            'title': id.split('/').last,
            'laneId': id.contains('review')
                ? 'licoup.lane/review'
                : 'licoup.lane/build',
            if (gateId != null && gateAnchors.contains(id)) 'gateId': gateId,
            'role': id.contains('review')
                ? 'licoup.role/reviewer'
                : 'licoup.role/builder',
            'execution': execution[id] ?? 'claimed',
            'acceptance': acceptance[id] ?? 'pending',
            'observation': observation[id] ?? 'fresh',
            'ready': ready[id] ?? true,
            'startable': startable[id] ?? true,
            'blockers': blockers[id] ?? <Object?>[],
            'actions': id.contains('review')
                ? <Object?>['licoup.action/unit-takeover']
                : <Object?>[
                    'licoup.action/unit-pause',
                    'licoup.action/unit-cancel',
                  ],
            'attempts': <Object?>[],
            'visits': <Object?>[],
            'events': <Object?>[],
            'evidence': <Object?>[],
            'consumes': <Object?>[],
            'results': <Object?>[],
          },
      ],
      'gates': <Object?>[
        if (gateId != null && gateAnchors.isNotEmpty)
          <String, Object?>{
            'id': gateId,
            'title': 'Alpha acceptance',
            'anchors': <Object?>[...gateAnchors],
            'runCount': runCount,
          },
      ],
    },
    ...extraProjects,
  ],
  'edges': <Object?>[...edges],
};

Map<String, Object?> projectJson({
  required String id,
  required String title,
  required List<String> nodeIds,
  String laneId = 'licoup.lane/build',
  String role = 'licoup.role/builder',
}) {
  final laneSuffix = id.split('/').last;
  return <String, Object?>{
    'id': id,
    'title': title,
    'lanes': <Object?>[
      <String, Object?>{
        'id': '$laneId-$laneSuffix',
        'title': 'Build',
        'order': 0,
      },
    ],
    'nodes': <Object?>[
      for (final node in nodeIds)
        <String, Object?>{
          'id': node,
          'title': node.split('/').last,
          'laneId': '$laneId-$laneSuffix',
          'role': role,
          'execution': 'not-started',
          'acceptance': 'pending',
          'observation': 'fresh',
          'ready': false,
          'startable': false,
          'blockers': <Object?>[
            <String, Object?>{
              'code': 'dependency_missing',
              'detail': 'waiting for the previous project',
            },
          ],
          'actions': <Object?>[],
          'attempts': <Object?>[],
          'visits': <Object?>[],
          'events': <Object?>[],
          'evidence': <Object?>[],
          'consumes': <Object?>[],
          'results': <Object?>[],
        },
    ],
    'gates': <Object?>[],
  };
}

/// Three projects where one shared gate has two reference anchors.
Map<String, Object?> threeProjectDocumentJson({
  int planRevision = 1,
}) => documentJson(
  planRevision: planRevision,
  nodeIds: <String>['licoup.node/alpha-build', 'licoup.node/alpha-review'],
  gateAnchors: <String>['licoup.node/alpha-build', 'licoup.node/alpha-review'],
  execution: const <String, String>{
    'licoup.node/alpha-build': 'running',
    'licoup.node/alpha-review': 'claimed',
  },
  acceptance: const <String, String>{'licoup.node/alpha-review': 'reviewing'},
  observation: const <String, String>{'licoup.node/alpha-review': 'stale'},
  startable: const <String, bool>{'licoup.node/alpha-review': false},
  blockers: const <String, List<Map<String, Object?>>>{
    'licoup.node/alpha-review': <Map<String, Object?>>[
      <String, Object?>{
        'code': 'conflicting_writer',
        'detail': 'an old writer still holds the review',
        'affects': <Object?>['licoup.node/alpha-review'],
      },
    ],
  },
  extraProjects: <Map<String, Object?>>[
    projectJson(
      id: 'licoup.project/beta',
      title: 'Beta',
      nodeIds: <String>['licoup.node/beta-build'],
    ),
    projectJson(
      id: 'licoup.project/gamma',
      title: 'Gamma',
      nodeIds: <String>['licoup.node/gamma-build'],
    ),
  ],
  edges: <Map<String, Object?>>[
    <String, Object?>{
      'id': 'licoup.edge/alpha-review-alpha-build',
      'from': 'licoup.node/alpha-build',
      'to': 'licoup.node/alpha-review',
      'kind': 'requires',
    },
    <String, Object?>{
      'id': 'licoup.edge/beta-alpha',
      'from': 'licoup.node/alpha-build',
      'to': 'licoup.node/beta-build',
      'kind': 'requires',
    },
  ],
);

/// The frozen budget scale: 8 projects, 1000 nodes, 2000 edges.
///
/// The first three projects keep the scenario identities the interaction
/// machine observes, so one document exercises both the product behavior and
/// the budget ceiling. Every edge points forward, so the graph is acyclic by
/// construction.
Map<String, Object?> wideScaleDocumentJson({int planRevision = 1}) {
  const projects = graphResourceMaxProjects; // 8
  const perProject = graphResourceMaxNodes ~/ projects; // 125
  const maxEdges = graphResourceMaxEdges; // 2000
  String nodeId(int project, int index) => 'licoup.node/p$project-$index';
  // The first three projects keep the scenario identities the interaction
  // model observes, so the profile run exercises the same user actions at the
  // budget scale instead of a second, unrelated document.
  const projectIds = <String>[
    'licoup.project/alpha',
    'licoup.project/beta',
    'licoup.project/gamma',
    'licoup.project/p3',
    'licoup.project/p4',
    'licoup.project/p5',
    'licoup.project/p6',
    'licoup.project/p7',
  ];
  String laneId(int project, int index) {
    final suffix = index.isEven ? 'build' : 'review';
    return switch (project) {
      0 => 'licoup.lane/$suffix',
      1 => 'licoup.lane/beta-$suffix',
      2 => 'licoup.lane/gamma-$suffix',
      _ => 'licoup.lane/p$project-$suffix',
    };
  }

  final projectList = <Map<String, Object?>>[];
  final edges = <Map<String, Object?>>[];
  // Identity order after the scenario overrides, so every edge points at a
  // node that really exists in the document.
  final resolvedIds = <List<String>>[];

  void addEdge(String from, String to, String kind) {
    edges.add(<String, Object?>{
      'id': 'licoup.edge/e${edges.length}',
      'from': from,
      'to': to,
      'kind': kind,
    });
  }

  for (var project = 0; project < projects; project++) {
    final ids = <String>[
      for (var index = 0; index < perProject; index++) nodeId(project, index),
    ];
    // The scenario identities stay in the first three projects.
    final nodes = <Map<String, Object?>>[
      for (var index = 0; index < perProject; index++)
        <String, Object?>{
          'id': ids[index],
          'title': 'Unit p$project-$index',
          'laneId': laneId(project, index),
          if (project == 0 && index == 0) 'gateId': 'licoup.gate/alpha-accept',
          if (project == 0 && index == 1) 'gateId': 'licoup.gate/alpha-accept',
          'role': index.isEven ? 'licoup.role/builder' : 'licoup.role/reviewer',
          'execution': index % 17 == 0 ? 'running' : 'not-started',
          'acceptance': index % 23 == 0 ? 'accepted' : 'pending',
          'observation': index % 29 == 0 ? 'stale' : 'fresh',
          'ready': index % 5 != 4,
          'startable': index % 7 == 0,
          'blockers': index % 13 == 0
              ? <Object?>[
                  <String, Object?>{
                    'code': 'dependency_missing',
                    'detail': 'waiting for the previous stage',
                    'affects': <Object?>[ids[index]],
                  },
                ]
              : <Object?>[],
          'actions': <Object?>[
            'licoup.action/unit-pause',
            'licoup.action/unit-cancel',
          ],
          'attempts': <Object?>[],
          'visits': <Object?>[],
          'events': <Object?>[],
          'evidence': <Object?>[],
          'consumes': <Object?>[],
          'results': <Object?>[],
        },
    ];
    // Keep the observable scenario ids of the small document.
    final firstId = project == 0
        ? 'licoup.node/alpha-build'
        : project == 1
        ? 'licoup.node/beta-build'
        : project == 2
        ? 'licoup.node/gamma-build'
        : ids.first;
    final secondId = project == 0 ? 'licoup.node/alpha-review' : ids[1];
    if (project == 0) {
      nodes[0] = <String, Object?>{
        ...nodes[0],
        'id': firstId,
        'title': 'Build alpha',
        'gateId': 'licoup.gate/alpha-accept',
        // The scenario semantics the interaction model observes: healthy and
        // running, so it is on the frontier and not an anomaly.
        'execution': 'running',
        'acceptance': 'pending',
        'observation': 'fresh',
        'ready': true,
        'startable': true,
        'blockers': <Object?>[],
      };
      nodes[1] = <String, Object?>{
        ...nodes[1],
        'id': secondId,
        'title': 'Review alpha',
        'laneId': laneId(0, 1),
        'gateId': 'licoup.gate/alpha-accept',
        'execution': 'claimed',
        'acceptance': 'reviewing',
        'observation': 'stale',
        'startable': false,
        'blockers': <Object?>[
          <String, Object?>{
            'code': 'conflicting_writer',
            'detail': 'an old writer still holds the review',
            'affects': <Object?>[secondId],
          },
        ],
        'actions': <Object?>['licoup.action/unit-takeover'],
      };
    } else if (project == 1 || project == 2) {
      nodes[0] = <String, Object?>{
        ...nodes[0],
        'id': firstId,
        'title': 'Build ${project == 1 ? 'beta' : 'gamma'}',
        'execution': 'not-started',
        'acceptance': 'pending',
        'observation': 'fresh',
        'startable': false,
        'ready': false,
        'blockers': <Object?>[
          <String, Object?>{
            'code': 'dependency_missing',
            'detail': 'waiting for alpha acceptance',
            'affects': <Object?>[firstId],
          },
        ],
      };
    }
    resolvedIds.add(<String>[for (final node in nodes) node['id']! as String]);
    projectList.add(<String, Object?>{
      'id': projectIds[project],
      'title': project == 0
          ? 'Alpha'
          : project == 1
          ? 'Beta'
          : project == 2
          ? 'Gamma'
          : 'Project $project',
      'lanes': <Object?>[
        <String, Object?>{
          'id': laneId(project, 0),
          'title': 'Build',
          'order': 0,
        },
        <String, Object?>{
          'id': laneId(project, 1),
          'title': 'Review',
          'order': 1,
        },
      ],
      'nodes': nodes,
      'gates': project == 0
          ? <Object?>[
              <String, Object?>{
                'id': 'licoup.gate/alpha-accept',
                'title': 'Alpha acceptance',
                'anchors': <Object?>[firstId, secondId],
                'runCount': 4,
              },
            ]
          : <Object?>[],
    });
  }

  // Chains: one edge per adjacent pair.
  for (var project = 0; project < projects; project++) {
    for (var index = 0; index + 1 < perProject; index++) {
      addEdge(
        resolvedIds[project][index],
        resolvedIds[project][index + 1],
        'requires',
      );
    }
  }
  // Skip-connections inside every project: real fan-out, still acyclic.
  for (var project = 0; project < projects; project++) {
    for (var index = 0; index + 2 < perProject; index++) {
      if (edges.length >= maxEdges) break;
      addEdge(
        resolvedIds[project][index],
        resolvedIds[project][index + 2],
        'requires',
      );
    }
  }
  // Cross-project edges from the alpha build unit to every other project.
  for (var project = 1; project < projects; project++) {
    if (edges.length >= maxEdges) break;
    addEdge('licoup.node/alpha-build', resolvedIds[project][0], 'requires');
  }
  // Fill to the exact frozen edge budget with forward edges of project zero.
  var span = 3;
  while (edges.length < maxEdges) {
    var added = false;
    for (
      var index = 0;
      index + span < perProject && edges.length < maxEdges;
      index++
    ) {
      addEdge(resolvedIds[0][index], resolvedIds[0][index + span], 'requires');
      added = true;
    }
    if (!added) break;
    span++;
  }

  return <String, Object?>{
    'schema': graphResourceV1Schema,
    'revision': planRevision,
    'projects': projectList,
    'edges': edges,
  };
}

/// A native owner stand-in for fixtures.
///
/// It is explicit: a product composition without a native owner gets
/// `project_collaboration_unavailable` refusals instead of these answers.
final class SyntheticProjectCollaborationOwner
    implements ProjectCollaborationActionOwner {
  SyntheticProjectCollaborationOwner({
    required this.currentRevision,
    this.takeoverRefusal,
    this.previewAffected = const <String>['licoup.node/alpha-review'],
    this.commitDelay,
  });

  int Function() currentRevision;

  /// When set, takeover is refused with this code, as a real conflicting writer
  /// would be.
  String? takeoverRefusal;

  final List<String> previewAffected;

  /// Optional delay so a test can observe the waiting state.
  Duration? commitDelay;

  int previewCounter = 0;
  int commitCount = 0;
  final List<String> performed = <String>[];

  @override
  Future<ProjectCollaborationReceipt> perform(
    ProjectCollaborationActionRequest request,
  ) async {
    performed.add(request.actionRef);
    switch (request.actionRef) {
      case ProjectCollaborationActions.insertPreview:
        previewCounter++;
        return ProjectCollaborationReceipt(
          actionRef: request.actionRef,
          accepted: true,
          code: 'previewed',
          revision: currentRevision(),
          previewRef: 'licoup.preview/$previewCounter',
          affectedNodeIds: previewAffected,
        );
      case ProjectCollaborationActions.insertCommit:
        if (commitDelay != null) await Future<void>.delayed(commitDelay!);
        final cited = request.values['previewRef'];
        if (cited == null || !cited.startsWith('licoup.preview/')) {
          return ProjectCollaborationReceipt(
            actionRef: request.actionRef,
            accepted: false,
            code: 'unknown_preview',
            revision: currentRevision(),
          );
        }
        commitCount++;
        return ProjectCollaborationReceipt(
          actionRef: request.actionRef,
          accepted: true,
          code: 'accepted',
          revision: currentRevision(),
          previewRef: cited,
        );
      case ProjectCollaborationActions.takeover:
        final refusal = takeoverRefusal;
        if (refusal != null) {
          return ProjectCollaborationReceipt(
            actionRef: request.actionRef,
            accepted: false,
            code: refusal,
            revision: currentRevision(),
            nodeId: request.nodeId,
          );
        }
        return ProjectCollaborationReceipt(
          actionRef: request.actionRef,
          accepted: true,
          code: 'accepted',
          revision: currentRevision(),
          nodeId: request.nodeId,
        );
      default:
        return ProjectCollaborationReceipt(
          actionRef: request.actionRef,
          accepted: true,
          code: 'accepted',
          revision: currentRevision(),
          nodeId: request.nodeId,
        );
    }
  }
}
