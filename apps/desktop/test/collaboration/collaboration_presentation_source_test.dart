import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/contracts/collaboration_run_port.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_effect.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_intent.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';
import 'package:licoup/src/projections/collaboration/collaboration_presentation_source.dart';

import 'support/collaboration_fixture.dart';

void main() {
  late FakeCollaborationRunPort port;
  late CollaborationPresentationSource source;

  setUp(() {
    port = FakeCollaborationRunPort();
    source = CollaborationPresentationSource(
      port: port,
      conversationId: 'conv-1',
    );
  });

  tearDown(() async {
    await source.dispose();
    await port.close();
  });

  Future<void> emitV2() async {
    port.emit(collabSnapshotV2());
    await pumpEventQueue();
  }

  test('the placeholder port reports unavailable', () async {
    final placeholder = CollaborationPresentationSource(
      port: const UnavailableCollaborationRunPort(),
      conversationId: 'conv-1',
    );
    addTearDown(placeholder.dispose);
    await pumpEventQueue();
    expect(
      placeholder.current.availability,
      CollaborationAvailability.unavailable,
    );
  });

  test('a snapshot produces an active projection', () async {
    expect(source.current.availability, CollaborationAvailability.loading);
    await emitV2();
    expect(source.current.isActive, isTrue);
    expect(source.current.headNumber, 2);
  });

  test('gate decision sends DecideGate with the current head', () async {
    await emitV2();
    source.send(const DecideCollaborationGate('gate-idx', 'full'));
    await pumpEventQueue();
    expect(port.sent, hasLength(1));
    final command = port.sent.single;
    expect(command, isA<DecideGate>());
    expect(command.expectedHead, 2);
    expect((command as DecideGate).gateId, 'gate-idx');
    expect(command.optionId, 'full');
  });

  test(
    'proposal commands send with the held revision and current head',
    () async {
      port.emit(collabSnapshotWithProposal());
      await pumpEventQueue();
      source.send(const ApproveCollaborationProposal());
      await pumpEventQueue();
      expect(port.sent.last, isA<ApproveProposal>());
      expect(port.sent.last.expectedHead, 1);
      expect((port.sent.last as ApproveProposal).number, 2);

      source.send(const RejectCollaborationProposal());
      await pumpEventQueue();
      expect(port.sent.last, isA<RejectProposal>());

      source.send(const RequestCollaborationRevision('加一个验证步骤'));
      await pumpEventQueue();
      final request = port.sent.last;
      expect(request, isA<RequestRevision>());
      expect((request as RequestRevision).note, '加一个验证步骤');
    },
  );

  test('revert sends RevertTo', () async {
    await emitV2();
    source.send(const RevertCollaborationRevision(1));
    await pumpEventQueue();
    expect(port.sent.last, isA<RevertTo>());
    expect((port.sent.last as RevertTo).number, 1);
    expect(port.sent.last.expectedHead, 2);
  });

  test('policy intents send SetPolicy commands', () async {
    await emitV2();
    source.send(
      const SetCollaborationPlanChangePolicy(CollaborationPlanChangePolicy.ask),
    );
    await pumpEventQueue();
    expect(port.sent.last, isA<SetPlanChangePolicy>());
    expect(port.sent.last.expectedHead, 2);

    source.send(
      const SetCollaborationGateReviewPolicy(
        CollaborationGateReviewPolicy.user,
      ),
    );
    await pumpEventQueue();
    expect(port.sent.last, isA<SetGateReviewPolicy>());
  });

  test('a conflict result emits CollaborationCommandConflicted', () async {
    await emitV2();
    port.nextResult = const CollaborationCommandResultConflict(5);
    final effects = <CollaborationEffect>[];
    final subscription = source.effects.listen(effects.add);
    addTearDown(subscription.cancel);
    source.send(const RevertCollaborationRevision(1));
    await pumpEventQueue();
    expect(effects, hasLength(1));
    expect(effects.single, isA<CollaborationCommandConflicted>());
    expect((effects.single as CollaborationCommandConflicted).currentHead, 5);
    expect(source.current.commandPending, isFalse);
  });

  test('a rejected result emits CollaborationCommandRejected', () async {
    await emitV2();
    port.nextResult = const CollaborationCommandResultRejected('nope');
    final effects = <CollaborationEffect>[];
    final subscription = source.effects.listen(effects.add);
    addTearDown(subscription.cancel);
    source.send(const RevertCollaborationRevision(1));
    await pumpEventQueue();
    expect((effects.single as CollaborationCommandRejected).code, 'nope');
  });

  test('selecting a revision loads its graph and drops states', () async {
    port.revisionGraphs[1] = collaborationGraphV1();
    await emitV2();
    source.send(const SelectCollaborationRevision(1));
    await pumpEventQueue();
    expect(port.loadCalls, [1]);
    expect(source.current.viewedNumber, 1);
    expect(source.current.viewingHead, isFalse);
    expect(source.current.nodeStates, isEmpty);
    expect(source.current.graph?.nodes, hasLength(12));
  });

  test('selecting null returns to the head without a load call', () async {
    await emitV2();
    source.send(const SelectCollaborationRevision(null));
    await pumpEventQueue();
    expect(port.loadCalls, isEmpty);
    expect(source.current.viewedNumber, 2);
  });

  test('dispose cancels the port subscription', () async {
    await emitV2();
    await source.dispose();
    port.emit(collabSnapshotV2());
    await pumpEventQueue();
    expect(source.current.isActive, isTrue); // frozen at dispose
  });
}
