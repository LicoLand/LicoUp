import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/agent_conversation_product_fixture.dart';

const _acceptanceEnabled = bool.fromEnvironment(
  'LICO_AGENT_CONVERSATION_PRODUCT_ACCEPTANCE',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'composer streams and precisely resumes one native Codex session',
    (tester) async {
      expect(
        _acceptanceEnabled,
        isTrue,
        reason: 'product acceptance must use its dedicated test build flag',
      );
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final conversationService = AcceptanceConversationService();
      final controller = createAcceptanceController(conversationService);

      await tester.pumpWidget(
        LicoApp(
          controllerFactory: () => controller,
          initializeController: false,
        ),
      );
      await tester.pumpAndSettle();

      await _submitComposer(tester, 'first acceptance turn');
      await tester.pump();
      expect(controller.selectedConversationAgentId, 'codex');
      expect(controller.selectedConversationAgent?.canRelayRuntime, isTrue);
      expect(controller.lastError, isEmpty);
      expect(conversationService.requests, hasLength(1));
      expect(controller.isSendingConversationMessage, isTrue);
      expect(conversationService.requests.single.sessionId, isEmpty);
      expect(conversationService.requests.single.model, acceptanceAgentModel);
      await _pumpUntilFound(tester, find.text('stream-one'));

      await tester.runAsync(conversationService.completeActiveTurn);
      await _waitForSendCompletion(tester, controller);
      await _pumpUntil(
        tester,
        () =>
            !controller.isSendingConversationMessage &&
            conversationService.historyReadCount >= 1,
      );
      expect(controller.lastError, isEmpty);
      expect(conversationService.historyReadCount, greaterThanOrEqualTo(1));
      expect(controller.isSendingConversationMessage, isFalse);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        acceptanceNativeSessionId,
      );
      await _submitComposer(tester, 'follow-up acceptance turn');
      await tester.pump();
      expect(controller.lastError, isEmpty);
      expect(
        controller.selectedConversationSession?.nativeSessionId,
        acceptanceNativeSessionId,
      );
      expect(conversationService.requests, hasLength(2));
      expect(
        conversationService.requests.last.sessionId,
        acceptanceNativeSessionId,
      );
      expect(conversationService.requests.last.model, acceptanceAgentModel);
      await _pumpUntilFound(tester, find.text('stream-two'));

      await tester.runAsync(conversationService.completeActiveTurn);
      await _waitForSendCompletion(tester, controller);
      await _pumpUntil(
        tester,
        () =>
            !controller.isSendingConversationMessage &&
            conversationService.historyReadCount >= 2,
      );
      expect(conversationService.historyReadCount, greaterThanOrEqualTo(2));
      final readback = controller.selectedConversationSession;
      expect(readback?.nativeSessionId, acceptanceNativeSessionId);
      expect(
        readback?.messages.map((message) => message.text),
        containsAll([
          'first acceptance turn',
          'stream-one complete',
          'follow-up acceptance turn',
          'stream-two complete',
        ]),
      );
      expect(conversationService.historyReadCount, greaterThanOrEqualTo(2));

      final summary = <String, Object>{
        'schemaVersion': 'lico-agent-conversation-product-e2e-v1',
        'status': 'passed',
        'flutterDriven': true,
        'acceptanceBuildFlag': _acceptanceEnabled,
        'composerSubmitted': true,
        'progressiveTimelineVisible': true,
        'sameNativeSessionId':
            conversationService.requests.length == 2 &&
            conversationService.requests.first.sessionId.isEmpty &&
            conversationService.requests.last.sessionId ==
                acceptanceNativeSessionId,
        'historyReadback': conversationService.historyReadCount >= 2,
        'model': acceptanceAgentModel,
        'turnCount': conversationService.requests.length,
      };
      final encoded = base64Url.encode(utf8.encode(jsonEncode(summary)));
      // The host runner emits only this bounded, content-free receipt.
      // ignore: avoid_print
      print('LICO_AGENT_CONVERSATION_PRODUCT_E2E $encoded');
    },
  );
}

Future<void> _submitComposer(WidgetTester tester, String text) async {
  final field = find.descendant(
    of: find.byKey(const Key('agent-conversation-composer-field')),
    matching: find.byType(TextField),
  );
  expect(field, findsOneWidget);
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.showKeyboard(field);
  final input = tester.widget<TextField>(field);
  input.controller!.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  await tester.pump();
  final send = find.byKey(const Key('agent-conversation-composer-send'));
  expect(send, findsOneWidget);
  final textField = tester.widget<TextField>(field);
  expect(textField.enabled, isTrue);
  expect(textField.onSubmitted, isNotNull);
  expect(textField.controller?.text, text);
  textField.onSubmitted!(text);
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 30 && finder.evaluate().isEmpty; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _waitForSendCompletion(
  WidgetTester tester,
  ClientController controller,
) async {
  await tester.runAsync(() async {
    for (
      var attempt = 0;
      attempt < 200 && controller.isSendingConversationMessage;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}
