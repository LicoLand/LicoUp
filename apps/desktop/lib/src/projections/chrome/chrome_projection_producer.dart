import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class ChromeProjectionProducer
    implements ProjectionSource<ChromeProjection> {
  ChromeProjectionProducer(ClientController controller)
    : _controller = controller,
      _current = _read(controller) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      controller.navigationController.changes.listen(_handleChange),
      controller.messagingNotificationCenter.changes.listen(_handleChange),
      controller.llmGatewayLifecycleController.changes.listen(_handleChange),
      controller.targetController.changes.listen(_handleChange),
      controller.conversationPresentationSignals.tabActivityChanges.listen(
        _handleChange,
      ),
    ];
  }

  final ClientController _controller;
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  final StreamController<ProjectionUpdate<ChromeProjection>> _changes =
      StreamController<ProjectionUpdate<ChromeProjection>>.broadcast(
        sync: true,
      );
  ChromeProjection _current;
  bool _closed = false;

  @override
  ChromeProjection get current => _current;

  @override
  Stream<ProjectionUpdate<ChromeProjection>> get changes => _changes.stream;

  void _handleChange(ApplicationChange change) {
    if (_closed) return;
    final next = _read(_controller);
    if (next == _current) return;
    _current = next;
    _changes.add(
      ProjectionUpdate<ChromeProjection>(
        next,
        trace: change.cause?.traceId == null
            ? null
            : TraceContext(traceId: change.cause!.traceId),
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await _changes.close();
  }

  static ChromeProjection _read(ClientController controller) {
    final selected = controller.navigationController.currentSection;
    return ChromeProjection(
      destinations: [
        for (final destination in ClientSection.values)
          ChromeDestinationProjection(
            destination: destination,
            label: destination.name,
            selected: destination == selected,
            enabled:
                !controller.mobileClientRuntimePlatform ||
                destination == ClientSection.agents ||
                destination == ClientSection.mobileRelay ||
                destination == ClientSection.settings,
          ),
      ],
      notifications: [
        for (final item in controller.messagingNotificationCenter.items)
          PresentationNotice(
            id: item.id,
            title: 'LicoUp',
            message: item.messageEnglish,
            severity: _severity(item.tone),
            reasonCode: item.code,
          ),
      ],
      operationNotifications: [
        for (final item in controller.messagingNotificationCenter.items)
          ChromeOperationNotificationProjection(
            id: item.id,
            messageChinese: item.messageChinese,
            messageEnglish: item.messageEnglish,
            severity: _severity(item.tone),
            reasonCode: item.code,
          ),
      ],
      agentNotifications: [
        for (final target in controller.scannedTargets)
          if (target.isConversationAgent &&
              controller.conversationTabActivityFor(target.id) !=
                  AgentConversationTabActivity.none)
            ChromeAgentNotificationProjection(
              target: target,
              activity: controller.conversationTabActivityFor(target.id),
              session: _latestSession(controller, target.id, target.target),
            ),
      ],
      gatewayNotification: _gatewayNotification(
        controller.llmGatewayLifecycleController,
      ),
      operationAutoRevealRevision:
          controller.messagingNotificationCenter.revision,
      gatewayAutoRevealRevision:
          controller.llmGatewayLifecycleController.autoRevealRevision,
      auxiliaryPanelOpen: false,
      searchAvailable: true,
    );
  }
}

ChromeGatewayNotificationProjection? _gatewayNotification(
  LlmGatewayLifecycleController controller,
) {
  final notice = controller.notice;
  if (notice == null) return null;
  return ChromeGatewayNotificationProjection(
    kind: switch (notice) {
      LlmGatewayNoticeKind.recovering => ChromeGatewayNoticeKind.recovering,
      LlmGatewayNoticeKind.recoveryFailed =>
        ChromeGatewayNoticeKind.recoveryFailed,
    },
    recoveryAttempt: controller.recoveryAttempt,
    maxRecoveryAttempts: LlmGatewayLifecycleController.maxRecoveryAttempts,
    busy: controller.busy,
  );
}

AgentConversationSession? _latestSession(
  ClientController controller,
  String id,
  String target,
) {
  final sessions =
      controller.conversationSessionsByAgent[id] ??
      controller.conversationSessionsByAgent[target] ??
      const <AgentConversationSession>[];
  AgentConversationSession? latest;
  for (final session in sessions) {
    if (latest == null ||
        _sessionSortTime(session) > _sessionSortTime(latest) ||
        (_sessionSortTime(session) == _sessionSortTime(latest) &&
            session.id.compareTo(latest.id) < 0)) {
      latest = session;
    }
  }
  return latest;
}

int _sessionSortTime(AgentConversationSession session) =>
    (DateTime.tryParse(session.updatedAt) ??
            DateTime.tryParse(session.createdAt) ??
            DateTime.fromMillisecondsSinceEpoch(0))
        .toUtc()
        .millisecondsSinceEpoch;

PresentationNoticeSeverity _severity(MessagingNotificationTone tone) =>
    switch (tone) {
      MessagingNotificationTone.info => PresentationNoticeSeverity.information,
      MessagingNotificationTone.warning => PresentationNoticeSeverity.warning,
      MessagingNotificationTone.failure => PresentationNoticeSeverity.error,
      MessagingNotificationTone.success => PresentationNoticeSeverity.success,
    };
