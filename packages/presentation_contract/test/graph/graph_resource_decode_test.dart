import 'dart:convert';
import 'dart:io';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:test/test.dart';

/// The published schema is the contract a producer validates against, so these
/// tests read it and compare the bounds, identifiers and closed enumerations
/// this package implements. An edit to one side is an edit to the other or a
/// failing test.
Map<String, Object?> schema() {
  // Resolve from the repository, whatever directory the runner started in.
  var directory = Directory.current;
  while (true) {
    final file = File(
      '${directory.path}/schemas/extensions/graph-resource.schema.json',
    );
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Run from the repository to read the published schema.');
    }
    directory = parent;
  }
}

Map<String, Object?> nodeJson(
  String id, {
  String lane = 'licoup.lane/build',
  String? gate,
  String execution = 'claimed',
  String acceptance = 'pending',
  String observation = 'fresh',
  bool ready = true,
  bool startable = true,
  List<Object?> blockers = const <Object?>[],
  List<Object?> consumes = const <Object?>[],
}) => <String, Object?>{
  'id': id,
  'title': 'Node $id',
  'laneId': lane,
  if (gate != null) 'gateId': gate,
  'role': 'licoup.role/builder',
  'execution': execution,
  'acceptance': acceptance,
  'observation': observation,
  'ready': ready,
  'startable': startable,
  'blockers': blockers,
  'consumes': consumes,
};

Map<String, Object?> documentJson({
  int revision = 3,
  List<Object?> nodes = const <Object?>[],
  List<Object?> edges = const <Object?>[],
  List<Object?> gates = const <Object?>[],
}) => <String, Object?>{
  'schema': graphResourceV1Schema,
  'revision': revision,
  'projects': <Object?>[
    <String, Object?>{
      'id': 'licoup.project/alpha',
      'title': 'Alpha',
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
      'nodes': nodes,
      'gates': gates,
    },
  ],
  'edges': edges,
};

void main() {
  test(
    'the published schema and this decoder agree on identity and bounds',
    () {
      final published = schema();
      Map<String, Object?> at(Object? value) =>
          (value as Map).map((key, entry) => MapEntry(key.toString(), entry));
      expect(
        at(at(published['properties'])['schema'])['const'],
        graphResourceV1Schema,
      );
      expect(
        at(at(published['properties'])['projects'])['maxItems'],
        graphResourceMaxProjects,
      );
      expect(
        at(at(published['properties'])['edges'])['maxItems'],
        graphResourceMaxEdges,
      );
      final defs = at(published['\$defs']);
      final project = at(defs['project']);
      expect(
        at(at(project['properties'])['nodes'])['maxItems'],
        graphResourceMaxNodes,
      );
      expect(at(defs['title'])['maxLength'], graphResourceMaxLabelBytes);
      expect(at(defs['detail'])['maxLength'], graphResourceMaxDetailBytes);
      expect(
        at(defs['opaqueRef'])['maxLength'],
        graphResourceMaxOpaqueRefBytes,
      );
      expect(
        at(defs['namespacedName'])['maxLength'],
        graphResourceMaxNamespacedNameBytes,
      );
      expect(published['additionalProperties'], isFalse);
    },
  );

  test('every published enumeration is the one this decoder accepts', () {
    Map<String, Object?> at(Object? value) =>
        (value as Map).map((key, entry) => MapEntry(key.toString(), entry));
    final defs = at(schema()['\$defs']);
    List<String> wireNames(Iterable<Enum> values) => <String>[
      for (final value in values)
        switch (value) {
          GraphExecutionState() => value.wireName,
          GraphAcceptanceState() => value.wireName,
          GraphObservationState() => value.wireName,
          GraphEdgeKind() => value.wireName,
          GraphResultKind() => value.wireName,
          GraphAttemptState() => value.wireName,
          GraphVisitKind() => value.wireName,
          GraphBlockerCode() => value.wireName,
          _ => throw StateError('unknown enumeration'),
        },
    ];
    // Each definition publishes its own closed enumeration under `properties`.
    var node = at(at(defs['node'])['properties']);
    expect(
      at(node['execution'])['enum'],
      wireNames(GraphExecutionState.values),
    );
    expect(
      at(node['acceptance'])['enum'],
      wireNames(GraphAcceptanceState.values),
    );
    expect(
      at(node['observation'])['enum'],
      wireNames(GraphObservationState.values),
    );
    node = at(at(defs['edge'])['properties']);
    expect(at(node['kind'])['enum'], wireNames(GraphEdgeKind.values));
    node = at(at(defs['resultRef'])['properties']);
    expect(at(node['kind'])['enum'], wireNames(GraphResultKind.values));
    node = at(at(defs['attempt'])['properties']);
    expect(at(node['state'])['enum'], wireNames(GraphAttemptState.values));
    node = at(at(defs['visit'])['properties']);
    expect(at(node['kind'])['enum'], wireNames(GraphVisitKind.values));
    node = at(at(defs['blocker'])['properties']);
    expect(at(node['code'])['enum'], wireNames(GraphBlockerCode.values));
  });

  test('a node has no place for code or secrets', () {
    Map<String, Object?> at(Object? value) =>
        (value as Map).map((key, entry) => MapEntry(key.toString(), entry));
    final defs = at(schema()['\$defs']);
    final node = at(at(defs['node'])['properties']);
    for (final forbidden in const <String>[
      'code',
      'script',
      'handler',
      'widget',
      'dart',
      'secret',
      'token',
      'credential',
    ]) {
      expect(node.containsKey(forbidden), isFalse, reason: forbidden);
    }
    expect(at(node['actions'])['items'], <String, Object?>{
      '\$ref': '#/\$defs/opaqueRef',
    });
  });

  test(
    'one decoded document exposes stable ids, consumers and gate identity',
    () {
      final value = GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[
            nodeJson(
              'licoup.node/alpha-build',
              gate: 'licoup.gate/alpha-accept',
            ),
            nodeJson(
              'licoup.node/alpha-review',
              lane: 'licoup.lane/review',
              gate: 'licoup.gate/alpha-accept',
              consumes: <Object?>[
                <String, Object?>{
                  'nodeId': 'licoup.node/alpha-build',
                  'kind': 'candidate',
                },
              ],
            ),
          ],
          edges: <Object?>[
            <String, Object?>{
              'id': 'licoup.edge/build-review',
              'from': 'licoup.node/alpha-build',
              'to': 'licoup.node/alpha-review',
              'kind': 'requires',
            },
          ],
          gates: <Object?>[
            <String, Object?>{
              'id': 'licoup.gate/alpha-accept',
              'title': 'Alpha acceptance',
              'anchors': <Object?>[
                'licoup.node/alpha-build',
                'licoup.node/alpha-review',
              ],
              'runCount': 4,
            },
          ],
        ),
      );
      expect(value.planRevision, 3);
      expect(value.nodeCount, 2);
      expect(value.edgeCount, 1);
      expect(
        value.node('licoup.node/alpha-build')!.laneId,
        'licoup.lane/build',
      );
      expect(value.index.consumersOf('licoup.node/alpha-build'), <String>[
        'licoup.node/alpha-review',
      ]);
      expect(value.index.consumersOf('licoup.node/alpha-review'), isEmpty);
      final gate = value.index.gateById['licoup.gate/alpha-accept']!;
      expect(gate.runCount, 4, reason: 'one gate carries one run count');
      expect(
        gate.anchors.length,
        2,
        reason: 'anchors do not duplicate the gate',
      );
      expect(value.index.anchorsOf('licoup.gate/alpha-accept').length, 2);
    },
  );

  test('structural violations are refused, never truncated', () {
    Matcher refuses(String code, String field) => throwsA(
      isA<GraphResourceFormatException>().having(
        (error) => error.refusal,
        'refusal',
        isA<GraphResourceRefusal>()
            .having((refusal) => refusal.code, 'code', code)
            .having((refusal) => refusal.field, 'field', field),
      ),
    );

    expect(
      () => GraphResourceValue.fromJson(documentJson(revision: 0)),
      refuses('graph_resource_invalid', 'revision'),
    );
    expect(
      () => GraphResourceValue.fromJson(<String, Object?>{
        ...documentJson(),
        'schema': 'licoup.ui.graph-resource.v2',
      }),
      refuses('graph_resource_unknown_schema', 'schema'),
    );
    expect(
      () => GraphResourceValue.fromJson(<String, Object?>{
        ...documentJson(),
        'extra': true,
      }),
      refuses('graph_resource_invalid', 'document.extra'),
    );
    expect(
      () => GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[
            nodeJson('licoup.node/a'),
            nodeJson('licoup.node/a'),
          ],
        ),
      ),
      refuses('graph_resource_invalid', 'nodes.id'),
    );
    expect(
      () => GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[nodeJson('licoup.node/a')],
          edges: <Object?>[
            <String, Object?>{
              'id': 'licoup.edge/x',
              'from': 'licoup.node/a',
              'to': 'licoup.node/missing',
              'kind': 'requires',
            },
          ],
        ),
      ),
      refuses('graph_resource_invalid', 'edges'),
    );
    expect(
      () => GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[nodeJson('licoup.node/a', execution: 'done')],
        ),
      ),
      refuses('graph_resource_invalid', 'node.status'),
    );
    expect(
      () => GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[
            nodeJson(
              'licoup.node/a',
              blockers: <Object?>[
                <String, Object?>{
                  'code': 'conflicting_writer',
                  'detail': 'writer still active',
                  'affects': <Object?>['licoup.node/ghost'],
                },
              ],
            ),
          ],
        ),
      ),
      refuses('graph_resource_invalid', 'nodes.blockers.affects'),
    );
    expect(
      () => GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[
            nodeJson('licoup.node/a', gate: 'licoup.gate/ghost'),
          ],
        ),
      ),
      refuses('graph_resource_invalid', 'nodes.gateId'),
    );
    expect(
      () => GraphResourceValue.fromJson(
        documentJson(
          nodes: <Object?>[
            for (var index = 0; index <= graphResourceMaxNodes; index++)
              nodeJson('licoup.node/n$index'),
          ],
        ),
      ),
      refuses('graph_resource_too_large', 'project.nodes'),
    );
  });

  test('a document over the project budget is refused as a whole', () {
    final project = <String, Object?>{
      'id': 'licoup.project/alpha',
      'title': 'Alpha',
      'lanes': <Object?>[
        <String, Object?>{
          'id': 'licoup.lane/build',
          'title': 'Build',
          'order': 0,
        },
      ],
      'nodes': <Object?>[nodeJson('licoup.node/a')],
      'gates': <Object?>[],
    };
    expect(
      () => GraphResourceValue.fromJson(<String, Object?>{
        'schema': graphResourceV1Schema,
        'revision': 1,
        'projects': <Object?>[
          for (var index = 0; index <= graphResourceMaxProjects; index++)
            <String, Object?>{...project, 'id': 'licoup.project/p$index'},
        ],
        'edges': <Object?>[],
      }),
      throwsA(
        isA<GraphResourceFormatException>().having(
          (error) => error.refusal.code,
          'code',
          'graph_resource_too_large',
        ),
      ),
    );
  });

  test('blocker codes carry the native reason, not a UI decision', () {
    final value = GraphResourceValue.fromJson(
      documentJson(
        nodes: <Object?>[
          nodeJson(
            'licoup.node/a',
            ready: false,
            startable: false,
            blockers: <Object?>[
              <String, Object?>{
                'code': 'authority_missing',
                'detail': 'original authority was withdrawn',
              },
              <String, Object?>{
                'code': 'conflicting_writer',
                'detail': 'an old writer still holds the unit',
                'affects': <Object?>['licoup.node/a'],
              },
            ],
          ),
        ],
      ),
    );
    final node = value.node('licoup.node/a')!;
    expect(node.ready, isFalse);
    expect(node.startable, isFalse);
    expect(node.blockers.first.code, GraphBlockerCode.authorityMissing);
    expect(node.mainBlocker!.detail, 'original authority was withdrawn');
    expect(node.blockers.last.affects, <String>['licoup.node/a']);
  });
}
