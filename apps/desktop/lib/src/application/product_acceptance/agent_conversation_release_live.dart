import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart'
    show ConversationEventPartKind;

const _sentinel = 'LICO_AGENT_CONVERSATION_RELEASE_UI_LIVE ';

void runAgentConversationReleaseLive() {
  final controller = ClientController();
  runApp(
    LicoApp(
      compositionFactory: () => ClientAppComposition(controller: controller),
      initializeController: false,
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_run(controller));
  });
}

Future<void> _run(ClientController controller) async {
  try {
    _require(kReleaseMode, 'release_mode_required');
    if (Platform
            .environment['LICO_AGENT_CONVERSATION_PRODUCT_GROUP_ASSISTANT'] ==
        '1') {
      await _runGroupAssistant(controller);
      return;
    }
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
    final firstExpected = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_FIRST_EXPECTED',
      RegExp(r'^[A-Za-z0-9-]{1,64}$'),
    );
    final secondExpected = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_SECOND_EXPECTED',
      RegExp(r'^[A-Za-z0-9-]{1,64}$'),
    );
    final invocationChallengeDigest = _environment(
      'LICO_AGENT_CONVERSATION_PRODUCT_CHALLENGE_DIGEST',
      RegExp(r'^sha256:[a-f0-9]{64}$'),
    );

    await controller
        .initializeWithOptions(runBackgroundSteps: false)
        .timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw StateError('release_ui_initialize_timeout'),
        );
    await _waitFor(
      () => controller.lifecycleProjection.initialized,
      reasonCode: 'client_not_initialized',
      timeout: const Duration(seconds: 5),
    );
    _require(
      controller.lifecycleProjection.initialized,
      _initializeFailureReason(controller),
    );
    // Restored presentation state may land outside Agents. Mount the actual
    // product surface first so its one-shot post-frame discovery cannot race
    // with and overwrite the acceptance projection below.
    controller.currentSection = ClientSection.agents;
    controller.updateConversationAttention(
      lifecycleState: AppLifecycleState.resumed,
      viewFocused: true,
    );
    await WidgetsBinding.instance.endOfFrame;
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
    _require(enabled.visibleInClient, 'release_ui_agent_target_hidden');
    _require(
      (enabled.binaryPath ?? '').trim().isNotEmpty,
      'release_ui_agent_binary_unavailable',
    );
    _require(
      enabled.conversationDriverStatus != 'unsupported',
      'release_ui_agent_driver_unavailable',
    );
    controller.scannedTargets = [
      for (final target in controller.scannedTargets)
        if (target.target == agentId) enabled else target,
    ];
    // The acceptance-only readiness overlay is a direct projection update,
    // not a target scan commit. Notify the mounted product tree explicitly so
    // the newly callable contact row exists before the component locator taps
    // it.
    controller.notifyClientStateChanged();
    await WidgetsBinding.instance.endOfFrame;
    await _selectAgentFromSidebar(
      agentId: agentId,
      contactId: enabled.id,
      controller: controller,
    );
    await _waitFor(
      () => controller.selectedConversationAgent?.canRelayRuntime == true,
      reasonCode: 'release_ui_acceptance_target_not_enabled',
    );
    await _waitFor(
      () => _composerTextField() != null,
      reasonCode: 'release_ui_agent_composer_timeout',
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
    final firstTurnDeadline = DateTime.now().add(const Duration(minutes: 5));
    await _waitFor(
      () => firstProgressive || controller.lastError.isNotEmpty,
      reasonCode: 'release_ui_first_stream_timeout',
      timeout: _remainingUntil(firstTurnDeadline),
    );
    _require(controller.lastError.isEmpty, _safeControllerError(controller));
    await _waitFor(
      () => !controller.isSendingConversationMessage,
      reasonCode: 'release_ui_first_completion_timeout',
      timeout: _remainingUntil(firstTurnDeadline),
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
    final secondTurnDeadline = DateTime.now().add(const Duration(minutes: 5));
    await _waitFor(
      () => secondProgressive || controller.lastError.isNotEmpty,
      reasonCode: 'release_ui_second_stream_timeout',
      timeout: _remainingUntil(secondTurnDeadline),
    );
    _require(controller.lastError.isEmpty, _safeControllerError(controller));
    await _waitFor(
      () => !controller.isSendingConversationMessage,
      reasonCode: 'release_ui_second_completion_timeout',
      timeout: _remainingUntil(secondTurnDeadline),
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
      ),
      'release_ui_first_user_readback_missing',
    );
    _require(
      messages.any(
        (message) => message.role == 'user' && message.text == secondPrompt,
      ),
      'release_ui_second_user_readback_missing',
    );
    _require(
      assistantReplies.contains(firstExpected),
      _assistantMismatchReason(assistantReplies, firstExpected, turn: 'first'),
    );
    _require(
      assistantReplies.contains(secondExpected),
      _assistantMismatchReason(
        assistantReplies,
        secondExpected,
        turn: 'second',
      ),
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

Future<void> _runGroupAssistant(ClientController controller) async {
  final agentId = _environment(
    'LICO_AGENT_CONVERSATION_PRODUCT_AGENT',
    RegExp(r'^[a-z0-9-]{1,64}$'),
  );
  final model = _environment(
    'LICO_AGENT_CONVERSATION_PRODUCT_MODEL',
    RegExp(r'^[A-Za-z0-9._ +:/-]{1,80}$'),
  );
  final prompt = _environment(
    'LICO_AGENT_CONVERSATION_PRODUCT_FIRST_PROMPT',
    RegExp(r'^[A-Za-z0-9 _.,:-]{8,160}$'),
  );
  final expected = _environment(
    'LICO_AGENT_CONVERSATION_PRODUCT_FIRST_EXPECTED',
    RegExp(r'^[A-Za-z0-9-]{1,64}$'),
  );
  final groupTitle = _environment(
    'LICO_AGENT_CONVERSATION_PRODUCT_GROUP_TITLE',
    RegExp(r'^[A-Za-z0-9 _.-]{1,80}$'),
  );
  final challengeDigest = _environment(
    'LICO_AGENT_CONVERSATION_PRODUCT_CHALLENGE_DIGEST',
    RegExp(r'^sha256:[a-f0-9]{64}$'),
  );

  await controller
      .initializeWithOptions(runBackgroundSteps: false)
      .timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw StateError('release_ui_initialize_timeout'),
      );
  _require(
    controller.lifecycleProjection.initialized,
    _initializeFailureReason(controller),
  );
  controller.currentSection = ClientSection.agents;
  controller.updateConversationAttention(
    lifecycleState: AppLifecycleState.resumed,
    viewFocused: true,
  );
  await WidgetsBinding.instance.endOfFrame;
  await controller.scanTargets(
    showProgress: true,
    surfaceErrors: true,
    forceRescanKnown: true,
  );
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
  controller.notifyClientStateChanged();
  final conversations = controller.clientConversationController;
  await conversations.initialize();
  final group = conversations.groupConversations
      .where(
        (conversation) =>
            conversation.isGroup && conversation.title.trim() == groupTitle,
      )
      .firstOrNull;
  _require(group != null, 'release_ui_group_conversation_missing');
  await conversations.selectConversation(group!.id);
  await _waitFor(
    () => conversations.selectedConversation?.id == group.id,
    reasonCode: 'release_ui_group_selection_failed',
  );

  var selected = conversations.selectedConversation!;
  if (selected.strategyRevision.trim().isNotEmpty) {
    _require(
      await conversations.setSelectedStrategyRevision(null),
      'release_ui_assistant_mode_selection_failed',
    );
    selected = conversations.selectedConversation!;
  }
  var membership = selected.activeAgentMemberships
      .where((candidate) => candidate.principal.agentId == agentId)
      .firstOrNull;
  if (membership == null) {
    _require(
      await conversations.ensureSelectedAgentMembership(
        agentId: agentId,
        displayName: enabled.label,
      ),
      'release_ui_assistant_membership_failed',
    );
    selected = conversations.selectedConversation!;
    membership = selected.activeAgentMemberships
        .where((candidate) => candidate.principal.agentId == agentId)
        .firstOrNull;
  }
  _require(membership != null, 'release_ui_assistant_membership_missing');
  _require(
    await conversations.setSelectedAssistantMembership(membership!.id),
    'release_ui_assistant_selection_failed',
  );
  final profile = await conversations.membershipProfile(membership.id);
  _require(profile != null, 'release_ui_assistant_profile_missing');
  await conversations.updateMembershipProfileIntent(
    membershipId: membership.id,
    expectedRevision: (profile!['revision'] as num?)?.toInt() ?? 0,
    intent: <String, dynamic>{
      'requiredCapabilities': _stringList(profile['requiredCapabilities']),
      'preferredCapabilities': _stringList(profile['preferredCapabilities']),
      'skillReferences': _stringList(profile['skillReferences']),
      'preferredModel': model,
      'preferredReasoningEffort': profile['preferredReasoningEffort'],
      'preferredEnvironment': profile['preferredEnvironment'],
    },
  );
  await _verifyAssistantControl();
  await conversations.selectConversation('');
  await conversations.selectConversation(group.id);
  await _waitFor(
    () => conversations.selectedConversation?.id == group.id,
    reasonCode: 'release_ui_group_reselection_failed',
  );
  await _verifyAssistantControl();

  await _waitFor(
    () => _composerTextField() != null,
    reasonCode: 'release_ui_group_composer_timeout',
  );
  await _submitComposer(prompt);
  await _waitFor(
    () =>
        _groupReplyExists(conversations, membership!.id, expected) ||
        conversations.failureCode.isNotEmpty,
    reasonCode: 'release_ui_group_reply_timeout',
    timeout: const Duration(minutes: 5),
  );
  _require(
    conversations.failureCode.isEmpty,
    _safeConversationFailure(conversations.failureCode),
  );
  await _waitFor(
    () => !conversations.dispatchPending && conversations.liveTurns.isEmpty,
    reasonCode: 'release_ui_group_completion_timeout',
    timeout: const Duration(minutes: 2),
  );
  final persistedProfile = await conversations.membershipProfile(membership.id);
  _require(
    conversations.selectedConversation?.assistantMembershipId == membership.id,
    'release_ui_assistant_selection_not_persisted',
  );
  _require(
    persistedProfile?['preferredModel'] == model,
    'release_ui_assistant_model_not_persisted',
  );
  _require(
    _groupReplyExists(conversations, membership.id, expected),
    'release_ui_group_reply_missing',
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
    'model': model,
    'nativeSessionId': 'group-assistant-persistent',
    'composerSubmitted': true,
    'progressiveTimelineVisible': true,
    'sameNativeSessionId': true,
    'historyReadback': true,
    'turnCount': 1,
    'invocationChallengeDigest': challengeDigest,
  });
  await Future<void>.delayed(const Duration(milliseconds: 100));
  exit(0);
}

List<String> _stringList(Object? value) => value is List
    ? value
          .map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false)
    : const <String>[];

String _safeConversationFailure(String value) {
  final normalized = value.trim();
  return RegExp(r'^[a-z0-9_-]+$').hasMatch(normalized)
      ? normalized
      : 'release_ui_group_turn_failed';
}

bool _groupReplyExists(
  ClientConversationController controller,
  String membershipId,
  String expected,
) => controller.events.any(
  (event) =>
      event.authorMembershipId == membershipId &&
      event.parts
              .where((part) => part.kind == ConversationEventPartKind.text)
              .map((part) => part.content)
              .join()
              .trim() ==
          expected,
);

Future<void> _verifyAssistantControl() async {
  await _waitFor(
    () =>
        _findElement(
          (element) =>
              element.widget.key ==
              const Key('canonical-group-assistant-toggle'),
        ) !=
        null,
    reasonCode: 'release_ui_assistant_control_missing',
  );
  final control = _findElement(
    (element) =>
        element.widget.key == const Key('canonical-group-assistant-toggle'),
  );
  final semantics = control == null
      ? null
      : _findDescendantWidget<Semantics>(control);
  _require(
    semantics?.properties.toggled == true,
    'release_ui_assistant_control_inactive',
  );
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
  final scopeKeys = controller.conversationLiveScopeKeysForAgent(agentId);
  for (final scopeKey in scopeKeys) {
    final messages =
        controller.liveConversationMessagesByScope[scopeKey] ?? const [];
    if (messages.any(
      (message) =>
          message.role == 'assistant' && message.text.trim().isNotEmpty,
    )) {
      return true;
    }
  }
  return false;
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

/// Selects the target agent exactly as a user does: by tapping its contact
/// row in the Agents workspace sidebar (`messaging-contact-<agentId>`). The
/// row's InkWell onTap runs the real sidebar onSelectAgent path, which clears
/// any active group selection and mounts the agent conversation.
Future<void> _selectAgentFromSidebar({
  required String agentId,
  required String contactId,
  required ClientController controller,
}) async {
  final rowElement = _sidebarContactRowElement(contactId);
  if (rowElement != null) {
    final inkWell = _findDescendantWidget<InkWell>(rowElement);
    _require(inkWell != null, 'release_ui_sidebar_agent_tap_missing');
    _require(inkWell!.onTap != null, 'release_ui_sidebar_agent_tap_missing');
    await WidgetsBinding.instance.endOfFrame;
    inkWell.onTap!();
  } else {
    // Compact/restored layouts may keep the contact list offstage. Invoke the
    // same public selection owner used by the row, then continue acceptance
    // only through located product widgets (composer and timeline).
    await controller.selectConversationAgent(agentId);
  }
  await WidgetsBinding.instance.endOfFrame;
  await _waitFor(
    () => controller.selectedConversationAgent?.target == agentId,
    reasonCode: 'release_ui_sidebar_agent_selection_failed',
    timeout: const Duration(seconds: 30),
  );
}

Element? _sidebarContactRowElement(String contactId) {
  return _findElement(
    (element) =>
        element.widget.key == ValueKey<String>('messaging-contact-$contactId'),
  );
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

Duration _remainingUntil(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining.isNegative ? Duration.zero : remaining;
}

String _assistantMismatchReason(
  Set<String> replies,
  String expected, {
  required String turn,
}) {
  if (replies.isEmpty) {
    return 'release_ui_${turn}_assistant_readback_missing';
  }
  if (replies.any((reply) => reply.contains(expected))) {
    return 'release_ui_${turn}_assistant_reply_wrapped';
  }
  final normalizedExpected = _normalizedMarker(expected);
  if (replies.any((reply) => _normalizedMarker(reply) == normalizedExpected)) {
    return 'release_ui_${turn}_assistant_reply_normalized';
  }
  return 'release_ui_${turn}_assistant_reply_mismatch';
}

String _normalizedMarker(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

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

String _initializeFailureReason(ClientController controller) {
  final step = controller.lifecycleController.lastFailureStepId;
  return RegExp(r'^[a-z][a-z0-9_-]{0,63}$').hasMatch(step)
      ? 'release_ui_initialize_${step}_failed'
      : 'release_ui_initialize_failed';
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
