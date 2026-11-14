import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';

import 'support/collaboration_fixture.dart';

void main() {
  group('collaboration run payload', () {
    test('a full synthetic payload parses into the projection model', () {
      final snapshot = CollaborationRunSnapshot.fromJson(
        collabSnapshotPayload(),
      );

      expect(snapshot.runId, 'run-1');
      expect(snapshot.conversationId, 'conv-1');
      expect(snapshot.status, CollaborationRunStatus.waiting);
      expect(snapshot.planChangePolicy, CollaborationPlanChangePolicy.auto);
      expect(
        snapshot.gateReviewPolicy,
        CollaborationGateReviewPolicy.assistant,
      );
      expect(snapshot.headNumber, 2);
      expect(snapshot.revisions, hasLength(2));
      expect(snapshot.head?.digest, '3f9a2c1b7e');
      expect(snapshot.head?.shortDigest, '3f9a2c1');
      expect(
        snapshot.head?.approval,
        CollaborationRevisionApproval.autoApplied,
      );
      expect(snapshot.graph.nodes, hasLength(13));
      expect(snapshot.graph.edges, hasLength(15));
      expect(snapshot.graph.initialNodeId, 'p1');
      expect(
        snapshot.nodeStates['idx']?.status,
        CollaborationNodeStatus.waitingUser,
      );
      expect(
        snapshot.nodeStates['idx']?.gate?.review,
        isA<CollaborationGateEscalated>(),
      );
      expect(
        snapshot.nodeStates['ui']?.gate?.review,
        isA<CollaborationGateAssistantApproved>(),
      );
      expect(snapshot.headDiff?.addedNodes, ['bench']);
      expect(
        snapshot.headDiff?.changeFor('s2')?.kind,
        CollaborationChangeKind.reassigned,
      );
    });

    Map<String, dynamic> payload() => collabSnapshotPayload();

    test('missing a required field throws the contract error', () {
      final broken = payload()..remove('head');
      expect(
        () => CollaborationRunSnapshot.fromJson(broken),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'collaboration_run_payload_invalid',
          ),
        ),
      );
    });

    test('an unknown enum wire name throws the contract error', () {
      final broken = payload();
      (broken['nodeStates'] as Map<String, dynamic>)['idx'] = {
        'status': 'mystery',
      };
      expect(
        () => CollaborationRunSnapshot.fromJson(broken),
        throwsA(isA<FormatException>()),
      );
    });

    test('more than 512 nodes throws the contract error', () {
      final broken = payload();
      (broken['graph'] as Map<String, dynamic>)['nodes'] = [
        for (var i = 0; i < 513; i++)
          {'id': 'n$i', 'kind': 'actor', 'label': 'n$i'},
      ];
      expect(
        () => CollaborationRunSnapshot.fromJson(broken),
        throwsA(isA<FormatException>()),
      );
    });

    test('more than 2048 edges throws the contract error', () {
      final broken = payload();
      final graph = broken['graph'] as Map<String, dynamic>;
      graph['nodes'] = [
        for (var i = 0; i < 100; i++)
          {'id': 'n$i', 'kind': 'actor', 'label': 'n$i'},
      ];
      graph['edges'] = [
        for (var i = 0; i < 2049; i++)
          {'from': 'n${i % 99}', 'to': 'n${(i % 99) + 1}', 'event': 'e$i'},
      ];
      (broken['nodeStates'] as Map<String, dynamic>).clear();
      expect(
        () => CollaborationRunSnapshot.fromJson(broken),
        throwsA(isA<FormatException>()),
      );
    });

    test('an edge to an unknown node throws the contract error', () {
      final broken = payload();
      ((broken['graph'] as Map<String, dynamic>)['edges'] as List).add({
        'from': 'idx',
        'to': 'ghost',
        'event': 'done',
      });
      expect(
        () => CollaborationRunSnapshot.fromJson(broken),
        throwsA(isA<FormatException>()),
      );
    });

    test('a nodeState for an unknown node throws the contract error', () {
      final broken = payload();
      (broken['nodeStates'] as Map<String, dynamic>)['ghost'] = {
        'status': 'pending',
      };
      expect(
        () => CollaborationRunSnapshot.fromJson(broken),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('collaboration commands', () {
    test('every command serializes expectedHead', () {
      final commands = <CollaborationCommand>[
        const ApproveProposal(number: 2, expectedHead: 1),
        const RejectProposal(number: 2, expectedHead: 1),
        const RequestRevision(number: 2, note: '重试', expectedHead: 1),
        const RevertTo(number: 1, expectedHead: 2),
        const DecideGate(gateId: 'gate-idx', optionId: 'full', expectedHead: 2),
        const SetPlanChangePolicy(
          policy: CollaborationPlanChangePolicy.ask,
          expectedHead: 2,
        ),
        const SetGateReviewPolicy(
          policy: CollaborationGateReviewPolicy.user,
          expectedHead: 2,
        ),
      ];
      for (final command in commands) {
        expect(
          command.toJson()['expectedHead'],
          command.expectedHead,
          reason: command.runtimeType.toString(),
        );
      }
      expect(
        const RequestRevision(
          number: 2,
          note: 'note',
          expectedHead: 1,
        ).toJson()['note'],
        'note',
      );
      expect(
        const SetPlanChangePolicy(
          policy: CollaborationPlanChangePolicy.auto,
          expectedHead: 2,
        ).toJson()['value'],
        'auto',
      );
      expect(
        const DecideGate(
          gateId: 'g',
          optionId: 'o',
          expectedHead: 3,
        ).toJson()['gateId'],
        'g',
      );
    });
  });
}
