import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_client/app.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';

import 'support/agent_conversation_product_fixture.dart';

const _acceptanceEnabled = bool.fromEnvironment(
  'LICO_AGENT_CONVERSATION_PRODUCT_ACCEPTANCE',
);
const _sentinel = 'LICO_AGENT_CONVERSATION_RELEASE_UI ';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final service = AcceptanceConversationService();
  final controller = createAcceptanceController(service);
  runApp(
    LicoApp(controllerFactory: () => controller, initializeController: false),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_runAcceptance(service, controller));
  });
}

Future<void> _runAcceptance(
  AcceptanceConversationService service,
  ClientController controller,
) async {
  try {
    _require(_acceptanceEnabled, 'acceptance_build_flag_missing');
    _require(kReleaseMode, 'release_mode_required');
    await _waitFor(
      () => _composerTextField() != null,
      reasonCode: 'release_ui_composer_timeout',
    );

    await _submitComposer('first acceptance turn');
    _require(service.requests.length == 1, 'first_request_missing');
    _require(service.requests.first.sessionId.isEmpty, 'first_session_not_new');
    _require(
      service.requests.first.model == acceptanceAgentModel,
      'first_model_mismatch',
    );
    await _waitFor(
      () => _textVisible('stream-one'),
      reasonCode: 'release_ui_first_stream_timeout',
    );

    await service.completeActiveTurn();
    await _waitFor(
      () =>
          controller.isSendingConversationMessage == false &&
          service.historyReadCount >= 1,
      reasonCode: 'release_ui_first_readback_timeout',
    );
    _require(
      controller.selectedConversationSession?.nativeSessionId ==
          acceptanceNativeSessionId,
      'first_native_session_missing',
    );

    await _submitComposer('follow-up acceptance turn');
    _require(service.requests.length == 2, 'second_request_missing');
    _require(
      service.requests.last.sessionId == acceptanceNativeSessionId,
      'exact_resume_missing',
    );
    _require(
      service.requests.last.model == acceptanceAgentModel,
      'second_model_mismatch',
    );
    await _waitFor(
      () => _textVisible('stream-two'),
      reasonCode: 'release_ui_second_stream_timeout',
    );

    await service.completeActiveTurn();
    await _waitFor(
      () =>
          controller.isSendingConversationMessage == false &&
          service.historyReadCount >= 2,
      reasonCode: 'release_ui_second_readback_timeout',
    );
    final readback = controller.selectedConversationSession;
    _require(
      readback?.nativeSessionId == acceptanceNativeSessionId,
      'history_native_session_mismatch',
    );
    final texts = readback?.messages.map((message) => message.text).toSet();
    _require(
      texts?.containsAll(const {
            'first acceptance turn',
            'stream-one complete',
            'follow-up acceptance turn',
            'stream-two complete',
          }) ==
          true,
      'history_readback_incomplete',
    );

    _emit(<String, Object>{
      'schemaVersion': 'lico-agent-conversation-release-ui-v1',
      'status': 'passed',
      'releaseMode': kReleaseMode,
      'packagedApplicationProcess': true,
      'flutterDriven': true,
      'composerSubmitted': true,
      'progressiveTimelineVisible': true,
      'sameNativeSessionId': true,
      'historyReadback': true,
      'agentId': acceptanceAgentId,
      'model': acceptanceAgentModel,
      'turnCount': service.requests.length,
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    exit(0);
  } catch (error) {
    final message = error is StateError ? error.message : null;
    final reasonCode =
        message is String && RegExp(r'^[a-z0-9_-]+$').hasMatch(message)
        ? message
        : 'release_ui_unexpected_failure';
    _emit(<String, Object>{
      'schemaVersion': 'lico-agent-conversation-release-ui-v1',
      'status': 'failed',
      'reasonCode': reasonCode,
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    exit(1);
  }
}

Future<void> _submitComposer(String text) async {
  final field = _composerTextField();
  _require(field != null, 'composer_field_missing');
  _require(field!.enabled == true, 'composer_field_disabled');
  _require(field.onSubmitted != null, 'composer_submit_missing');
  field.controller!.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  await WidgetsBinding.instance.endOfFrame;
  field.onSubmitted!(text);
  await WidgetsBinding.instance.endOfFrame;
}

TextField? _composerTextField() {
  final composer = _findElement(
    (element) =>
        element.widget.key == const Key('agent-conversation-composer-field'),
  );
  if (composer == null) return null;
  return _findDescendantWidget<TextField>(composer);
}

bool _textVisible(String value) {
  return _findElement(
        (element) =>
            element.widget is Text &&
            (element.widget as Text).data == value &&
            element.renderObject?.attached == true,
      ) !=
      null;
}

Element? _findElement(bool Function(Element element) predicate) {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return null;
  Element? match;
  void visit(Element element) {
    if (match != null) return;
    if (predicate(element)) {
      match = element;
      return;
    }
    element.visitChildElements(visit);
  }

  visit(root);
  return match;
}

T? _findDescendantWidget<T extends Widget>(Element root) {
  T? match;
  void visit(Element element) {
    if (match != null) return;
    if (element.widget case final T widget) {
      match = widget;
      return;
    }
    element.visitChildElements(visit);
  }

  root.visitChildElements(visit);
  return match;
}

Future<void> _waitFor(
  bool Function() predicate, {
  String reasonCode = 'release_ui_condition_timeout',
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError(reasonCode);
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void _require(bool condition, String reasonCode) {
  if (!condition) throw StateError(reasonCode);
}

void _emit(Map<String, Object> receipt) {
  final encoded = base64Url.encode(utf8.encode(jsonEncode(receipt)));
  final line = '$_sentinel$encoded';
  final receiptPath =
      Platform.environment['LICO_AGENT_CONVERSATION_PRODUCT_RECEIPT'];
  if (receiptPath != null && receiptPath.isNotEmpty) {
    final file = File(receiptPath);
    if (!file.isAbsolute || !file.parent.existsSync()) {
      throw StateError('release_ui_receipt_path_invalid');
    }
    file.writeAsStringSync('$line\n', flush: true);
  }
  stdout.writeln(line);
}
