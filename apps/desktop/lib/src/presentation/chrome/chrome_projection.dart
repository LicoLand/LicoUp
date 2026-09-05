import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

enum ChromeGatewayNoticeKind { recovering, recoveryFailed }

final class ChromeGatewayNotificationProjection {
  const ChromeGatewayNotificationProjection({
    required this.kind,
    required this.recoveryAttempt,
    required this.maxRecoveryAttempts,
    required this.busy,
  });

  final ChromeGatewayNoticeKind kind;
  final int recoveryAttempt;
  final int maxRecoveryAttempts;
  final bool busy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChromeGatewayNotificationProjection &&
          other.kind == kind &&
          other.recoveryAttempt == recoveryAttempt &&
          other.maxRecoveryAttempts == maxRecoveryAttempts &&
          other.busy == busy;

  @override
  int get hashCode =>
      Object.hash(kind, recoveryAttempt, maxRecoveryAttempts, busy);
}

final class ChromeOperationNotificationProjection {
  const ChromeOperationNotificationProjection({
    required this.id,
    required this.messageChinese,
    required this.messageEnglish,
    required this.severity,
    this.reasonCode = '',
  });

  final String id;
  final String messageChinese;
  final String messageEnglish;
  final PresentationNoticeSeverity severity;
  final String reasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChromeOperationNotificationProjection &&
          other.id == id &&
          other.messageChinese == messageChinese &&
          other.messageEnglish == messageEnglish &&
          other.severity == severity &&
          other.reasonCode == reasonCode;

  @override
  int get hashCode =>
      Object.hash(id, messageChinese, messageEnglish, severity, reasonCode);
}

final class ChromeAgentNotificationProjection {
  const ChromeAgentNotificationProjection({
    required this.target,
    required this.activity,
    this.session,
  });

  final TargetCandidate target;
  final AgentConversationTabActivity activity;
  final AgentConversationSession? session;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChromeAgentNotificationProjection &&
          other.target == target &&
          other.activity == activity &&
          other.session == session;

  @override
  int get hashCode => Object.hash(target, activity, session);
}

final class ChromeDestinationProjection {
  const ChromeDestinationProjection({
    required this.destination,
    required this.label,
    required this.selected,
    required this.enabled,
  });

  final ClientSection destination;
  final String label;
  final bool selected;
  final bool enabled;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChromeDestinationProjection &&
          other.destination == destination &&
          other.label == label &&
          other.selected == selected &&
          other.enabled == enabled;

  @override
  int get hashCode => Object.hash(destination, label, selected, enabled);
}

final class ChromeProjection {
  ChromeProjection({
    required Iterable<ChromeDestinationProjection> destinations,
    required Iterable<PresentationNotice> notifications,
    Iterable<ChromeOperationNotificationProjection> operationNotifications =
        const <ChromeOperationNotificationProjection>[],
    Iterable<ChromeAgentNotificationProjection> agentNotifications =
        const <ChromeAgentNotificationProjection>[],
    this.gatewayNotification,
    this.operationAutoRevealRevision = 0,
    this.gatewayAutoRevealRevision = 0,
    required this.auxiliaryPanelOpen,
    required this.searchAvailable,
  }) : destinations = immutablePresentationList(destinations),
       notifications = immutablePresentationList(notifications),
       operationNotifications = immutablePresentationList(
         operationNotifications,
       ),
       agentNotifications = immutablePresentationList(agentNotifications);

  final List<ChromeDestinationProjection> destinations;
  final List<PresentationNotice> notifications;
  final List<ChromeOperationNotificationProjection> operationNotifications;
  final List<ChromeAgentNotificationProjection> agentNotifications;
  final ChromeGatewayNotificationProjection? gatewayNotification;
  final int operationAutoRevealRevision;
  final int gatewayAutoRevealRevision;
  final bool auxiliaryPanelOpen;
  final bool searchAvailable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChromeProjection &&
          samePresentationList(other.destinations, destinations) &&
          samePresentationList(other.notifications, notifications) &&
          samePresentationList(
            other.operationNotifications,
            operationNotifications,
          ) &&
          samePresentationList(other.agentNotifications, agentNotifications) &&
          other.gatewayNotification == gatewayNotification &&
          other.operationAutoRevealRevision == operationAutoRevealRevision &&
          other.gatewayAutoRevealRevision == gatewayAutoRevealRevision &&
          other.auxiliaryPanelOpen == auxiliaryPanelOpen &&
          other.searchAvailable == searchAvailable;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(destinations),
    Object.hashAll(notifications),
    Object.hashAll(operationNotifications),
    Object.hashAll(agentNotifications),
    gatewayNotification,
    operationAutoRevealRevision,
    gatewayAutoRevealRevision,
    auxiliaryPanelOpen,
    searchAvailable,
  );
}
