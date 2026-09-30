import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';

import 'conversation_control_under_flood_test.dart';

/// Detach proof for the shell control path.
///
/// The synthetic host, the composition and the recording instruments are the
/// shared setup of `conversation_control_under_flood_test.dart`: the substitute
/// stays at the process seam, and the intent routing, the port encoding and the
/// plane admission stay real.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'closing a conversation view stops observing without cancelling the '
    'running turn, and the turn still reaches its terminal settlement',
    () async {
      final harness = await ConversationFloodHarness.start(
        fixtureNode: 'NODE-015',
        // The detach proof needs a turn that is still running, not a long
        // decode backlog: a smaller bulk burst keeps the same flood shape while
        // the view lifecycle is what is measured.
        host: ConversationFloodHost(bulkFrames: 4, releasedBulkFrames: 2),
      );
      addTearDown(harness.close);
      try {
        await _proveDetachWithoutCancel(harness);
      } on Object {
        writeFloodDiagnostics('NODE-015', harness.diagnostics());
        rethrow;
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// AC-006: closing a view detaches observation without cancelling the work.
Future<void> _proveDetachWithoutCancel(ConversationFloodHarness harness) async {
  final host = harness.host;
  final port = harness.port;

  await harness.startFloodedTurn(text: 'detach probe question');
  final execution = harness.composition.binding.execution!;
  final published = <ConversationExecutionProjection>[];
  final subscription = execution.changes.listen(
    (update) => published.add(update.value),
  );
  addTearDown(subscription.cancel);

  final closedView = ConversationExecutionViewId();
  harness.sendIntent(
    OpenConversationExecutionView(
      viewId: closedView,
      reference: harness.executionReference,
    ),
  );
  await waitForCondition(
    () => execution.current.views[closedView]?.records.isNotEmpty ?? false,
    reason: 'the conversation view to admit execution records',
  );

  // The witness surface is opened only after the first one is live: this fixture
  // keeps one conversation-lane observation request in flight at a time, so the
  // proof does not depend on two of them overlapping.
  final witnessView = ConversationExecutionViewId();
  harness.sendIntent(
    OpenConversationExecutionView(
      viewId: witnessView,
      reference: harness.executionReference,
    ),
  );
  await waitForCondition(
    () => execution.current.views[witnessView]?.records.isNotEmpty ?? false,
    reason: 'the witness surface to admit execution records',
  );
  expect(
    host.executionRequests,
    hasLength(2),
    reason: 'each view owns its own native observation',
  );
  expect(
    host.detachRequests,
    isEmpty,
    reason: 'an open view does not detach its observation',
  );

  // The view is closed while the turn is still running: its native terminal has
  // not been delivered and its bulk output stream is still open.
  expect(harness.controller.isSendingConversationMessage, isTrue);
  expect(
    host.terminalWritten,
    isFalse,
    reason: 'the turn must still be running when the view closes',
  );
  final closedRecordsAtClose =
      execution.current.views[closedView]!.records.length;
  final publishedBeforeClose = published.length;

  harness.sendIntent(CloseConversationExecutionView(closedView));

  await waitForCondition(
    () => !execution.current.views.containsKey(closedView),
    reason: 'the closed surface to leave the projection',
  );

  // The native session keeps publishing records for this turn. The witness
  // surface observes them; the closed surface observes none of them and never
  // reappears in a published projection.
  final witnessBefore = execution.current.views[witnessView]!.records.length;
  host.pushExecutionRecords(2);
  await waitForCondition(
    () => execution.current.views[witnessView]!.records.length > witnessBefore,
    reason: 'the witness surface to keep observing the running turn',
  );
  await waitForCondition(
    () => host.detachRequests.isNotEmpty,
    reason: 'the released observation to be detached natively',
  );
  await Future<void>.delayed(const Duration(milliseconds: 20));
  expect(closedRecordsAtClose, greaterThan(0));
  expect(
    execution.current.views[closedView],
    isNull,
    reason: 'a closed surface observes no further events',
  );
  for (final snapshot in published.skip(publishedBeforeClose)) {
    expect(snapshot.views.containsKey(closedView), isFalse);
  }

  // Detaching observation is not cancellation: no cancel operation reached the
  // port and none reached the synthetic process seam, while the turn kept
  // running and the released observation was detached natively.
  expect(port.named('cancel'), isEmpty);
  expect(host.cancelRequests, isEmpty);
  expect(host.cancelFrameCount, 0);
  expect(host.seamMethods, isNot(contains('agent.conversation.cancel')));
  expect(harness.controller.isSendingConversationMessage, isTrue);
  expect(host.detachRequests, hasLength(1));
  expect(host.detachRequests.single['turnHandle'], host.turnHandle);
  expect(host.detachRequests.single['conversationId'], host.conversationId);

  // The turn itself was never cancelled and still reaches its own terminal
  // settlement, which the closed view could not observe.
  host.releaseTurn();
  await waitForCondition(
    () => !harness.controller.isSendingConversationMessage,
    reason: 'the detached turn to reach its terminal settlement',
  );
  await waitForCondition(
    () => port.named('send').single.settled,
    reason: 'the send stream terminal to settle',
  );
  final terminal = port.named('send').single.terminal;
  expect(terminal?['ok'], isTrue);
  expect(terminal?['turnStatus'], 'completed');
  expect(harness.controller.lastError, isEmpty);
  expect(port.named('cancel'), isEmpty);
  expect(host.cancelRequests, isEmpty);
  final admitted =
      harness.controller.selectedConversationSession?.messages ?? const [];
  expect(
    admitted.map((message) => message.text).join('\n'),
    contains('chunk-'),
    reason: 'the terminal settlement was still admitted',
  );
  final summary =
      'TASK-003 view-detach: closedRecords=$closedRecordsAtClose '
      'witnessRecords=${execution.current.views[witnessView]!.records.length} '
      'cancelOperations=${port.named('cancel').length} '
      'detachOperations=${host.detachRequests.length} '
      'terminalAdmitted=${terminal?['turnStatus']}';
  writeFloodEvidence('NODE-015', '$summary\n${harness.diagnostics()}');
  // ignore: avoid_print
  print(summary);
}
