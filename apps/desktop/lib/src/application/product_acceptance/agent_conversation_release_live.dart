import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

const _sentinel = 'LICO_AGENT_CONVERSATION_RELEASE_UI_LIVE ';

void runAgentConversationReleaseLive() {
  final controller = ClientController();
  runApp(LicoApp(controllerFactory: () => controller));
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_run(controller));
  });
}

Future<void> _run(ClientController controller) async {
  try {
    _require(kReleaseMode, 'release_mode_required');
    final agentId = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_AGENT',
      RegExp(r'^[a-z0-9-]{1,64}$'),
    );
    final model = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_MODEL',
      RegExp(r'^[A-Za-z0-9._ +:/-]{1,80}$'),
    );
    final firstPrompt = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_FIRST_PROMPT',
      RegExp(r'^[A-Za-z0-9 _.,:-]{8,160}$'),
    );
    final secondPrompt = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_SECOND_PROMPT',
      RegExp(r'^[A-Za-z0-9 _.,:-]{8,160}$'),
    );
    final invocationChallengeDigest = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_CHALLENGE_DIGEST',
      RegExp(r'^sha256:[a-f0-9]{64}$'),
    );

    await _waitFor(
      () => controller.lifecycleProjection.initialized,
      reasonCode: 'release_ui_initialize_timeout',
      timeout: const Duration(seconds: 45),
    );
    await controller.scanTargets(
      showProgress: true,
      surfaceErrors: true,
      forceRescanKnown: true,
    );
    // AgentsCanvas may have started its own post-frame discovery before this
    // acceptance task. scanTargets intentionally coalesces concurrent scans,
    // so awaiting the call alone does not prove that the in-flight scan has
    // committed. Never inject the acceptance-only ready projection until the
    // shared scanner is idle, otherwise its canonical unverified result can
    // overwrite the projection and disable the composer.
    await _waitFor(
      () => !controller.isScanningTargets,
      reasonCode: 'release_ui_target_scan_timeout',
      timeout: const Duration(minutes: 2),
    );
    final scanned = controller.scannedTargets
        .where((target) => target.target == agentId)
        .firstOrNull;
    _require(scanned != null, 'release_ui_agent_runtime_unavailable');
    final enabled = _acceptanceEnabledCandidate(scanned!);
    controller.scannedTargets = [
      for (final target in controller.scannedTargets)
        if (target.target == agentId) enabled else target,
    ];
    controller.currentSection = ClientSection.agents;
    controller.updateConversationAttention(
      lifecycleState: AppLifecycleState.resumed,
      viewFocused: true,
    );
    await controller.selectConversationAgent(agentId);
    await _waitFor(
      () => controller.selectedConversationAgent?.canRelayRuntime == true,
      reasonCode: 'release_ui_acceptance_target_not_enabled',
    );
    controller.startNewConversationSession();
    if (model.isNotEmpty &&
        controller.selectedConversationModelOptions.contains(model)) {
      controller.selectConversationModel(model);
    }
    await _waitFor(
      () => _composerTextField() != null,
      reasonCode: 'release_ui_composer_timeout',
    );

    var firstProgressive = false;
    void observeFirst() {
      firstProgressive =
          firstProgressive || _hasProgressiveAssistant(controller, agentId);
    }

    controller.addListener(observeFirst);
    await _submitComposer(firstPrompt);
    await _waitFor(
      () => firstProgressive || controller.lastError.isNotEmpty,
      reasonCode: 'release_ui_first_stream_timeout',
      timeout: const Duration(minutes: 10),
    );
    _require(controller.lastError.isEmpty, _safeControllerError(controller));
    await _waitFor(
      () => !controller.isSendingConversationMessage,
      reasonCode: 'release_ui_first_completion_timeout',
      timeout: const Duration(minutes: 10),
    );
    controller.removeListener(observeFirst);
    _require(controller.lastError.isEmpty, _safeControllerError(controller));
    await _waitFor(
      () =>
          controller.selectedConversationSession?.nativeSessionId
              .trim()
              .isNotEmpty ==
          true,
      reasonCode: 'release_ui_first_readback_timeout',
      timeout: const Duration(seconds: 60),
    );
    final nativeSessionId = controller
        .selectedConversationSession!
        .nativeSessionId
        .trim();

    var secondProgressive = false;
    void observeSecond() {
      secondProgressive =
          secondProgressive || _hasProgressiveAssistant(controller, agentId);
    }

    controller.addListener(observeSecond);
    await _submitComposer(secondPrompt);
    await _waitFor(
      () => secondProgressive || controller.lastError.isNotEmpty,
      reasonCode: 'release_ui_second_stream_timeout',
      timeout: const Duration(minutes: 10),
    );
    _require(controller.lastError.isEmpty, _safeControllerError(controller));
    await _waitFor(
      () => !controller.isSendingConversationMessage,
      reasonCode: 'release_ui_second_completion_timeout',
      timeout: const Duration(minutes: 10),
    );
    controller.removeListener(observeSecond);
    _require(controller.lastError.isEmpty, _safeControllerError(controller));
    // Each completed send performs an exact native-session readback before it
    // clears the live projection. Reuse that bounded result instead of a full
    // provider-history scan, which is unrelated to same-session acceptance.
    final readback = controller.selectedConversationSession;
    _require(
      readback?.nativeSessionId.trim() == nativeSessionId,
      'release_ui_native_session_mismatch',
    );
    final messages = readback?.messages ?? const [];
    final assistantReplies = messages
        .where((message) => message.role == 'assistant')
        .map((message) => message.text.trim())
        .toSet();
    _require(
      messages.any(
            (message) => message.role == 'user' && message.text == firstPrompt,
          ) &&
          messages.any(
            (message) => message.role == 'user' && message.text == secondPrompt,
          ) &&
          assistantReplies.contains(_expectedReply(firstPrompt)) &&
          assistantReplies.contains(_expectedReply(secondPrompt)),
      'release_ui_history_readback_incomplete',
    );

    _emit(<String, Object>{
      'schemaVersion': 'lico-agent-conversation-release-ui-live-v1',
      'status': 'passed',
      'receiptKind': 'release-ui-live',
      'releaseMode': true,
      'packagedApplicationProcess': true,
      'packagedSidecarUsed': true,
      'fixtureBackend': false,
      'agentId': agentId,
      'model': controller.selectedConversationModel.trim().isNotEmpty
          ? controller.selectedConversationModel
          : model,
      'nativeSessionId': nativeSessionId,
      'composerSubmitted': true,
      'progressiveTimelineVisible': firstProgressive && secondProgressive,
      'sameNativeSessionId': true,
      'historyReadback': true,
      'turnCount': 2,
      'invocationChallengeDigest': invocationChallengeDigest,
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    exit(0);
  } catch (error) {
    _emit(<String, Object>{
      'schemaVersion': 'lico-agent-conversation-release-ui-live-v1',
      'status': 'failed',
      'receiptKind': 'release-ui-live',
      'reasonCode': _safeReason(error),
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    exit(1);
  }
}

String _expectedReply(String prompt) {
  const prefix = 'Reply with exactly ';
  _require(prompt.startsWith(prefix), 'release_ui_prompt_contract_invalid');
  final reply = prompt.substring(prefix.length).trim();
  _require(reply.isNotEmpty, 'release_ui_prompt_contract_invalid');
  return reply;
}

TargetCandidate _acceptanceEnabledCandidate(TargetCandidate source) {
  final json = source.toJson();
  final capabilities = Map<String, dynamic>.from(source.adapterCapabilities)
    ..['conversationReadiness'] = 'ready'
    ..['conversationBlocker'] = ''
    ..['conversationSummaryCodes'] = const <String>[];
  final actions = {...source.supportedActions, 'runtime.message.send'}.toList();
  json['adapterCapabilities'] = capabilities;
  json['supportedActions'] = actions;
  return TargetCandidate.fromJson(json);
}

bool _hasProgressiveAssistant(ClientController controller, String agentId) {
  final messages =
      controller.liveConversationMessagesByAgent[agentId] ?? const [];
  return messages.any(
    (message) => message.role == 'assistant' && message.text.trim().isNotEmpty,
  );
}

Future<void> _submitComposer(String text) async {
  final field = _composerTextField();
  _require(field != null, 'release_ui_composer_missing');
  _require(field!.enabled == true, 'release_ui_composer_disabled');
  _require(field.onSubmitted != null, 'release_ui_submit_missing');
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
  return composer == null ? null : _findDescendantWidget<TextField>(composer);
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
  required String reasonCode,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(reasonCode);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

String _environment(String name, RegExp pattern) {
  final value = Platform.environment[name]?.trim() ?? '';
  if (!pattern.hasMatch(value)) {
    throw StateError('release_ui_environment_invalid');
  }
  return value;
}

String _safeControllerError(ClientController controller) {
  final value = controller.lastError.trim();
  return RegExp(r'^[a-z0-9_-]+$').hasMatch(value)
      ? value
      : 'release_ui_agent_turn_failed';
}

String _safeReason(Object error) {
  final value = error is StateError ? error.message : null;
  return value is String && RegExp(r'^[a-z0-9_-]+$').hasMatch(value)
      ? value
      : 'release_ui_unexpected_failure';
}

void _require(bool condition, String reasonCode) {
  if (!condition) throw StateError(reasonCode);
}

void _emit(Map<String, Object> receipt) {
  final encoded = base64Url.encode(utf8.encode(jsonEncode(receipt)));
  final line = '$_sentinel$encoded';
  final receiptPath =
      Platform.environment['LICO_AGENT_CONVERSATION_PRODUCT_RECEIPT'];
  if (receiptPath == null || receiptPath.isEmpty) {
    throw StateError('release_ui_receipt_path_missing');
  }
  final file = File(receiptPath);
  if (!file.isAbsolute || !file.parent.existsSync()) {
    throw StateError('release_ui_receipt_path_invalid');
  }
  file.writeAsStringSync('$line\n', flush: true);
  stdout.writeln(line);
}
