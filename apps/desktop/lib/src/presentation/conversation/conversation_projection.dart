import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/provider_quota_models.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

enum ConversationAuthority { nativeCatalog, canonicalConversation }

enum ConversationPartKind {
  text,
  reasoning,
  tool,
  artifact,
  diagnostic,
  metadata,
}

enum PersistentTurnPhase { idle, running, waiting, completed, failed }

final class ConversationProjection {
  const ConversationProjection({
    required this.authority,
    required this.conversationId,
    required this.membershipId,
  });

  final ConversationAuthority authority;
  final String conversationId;
  final String membershipId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationProjection &&
          other.authority == authority &&
          other.conversationId == conversationId &&
          other.membershipId == membershipId;

  @override
  int get hashCode => Object.hash(authority, conversationId, membershipId);
}

final class NativeConversationSessionProjection {
  const NativeConversationSessionProjection({
    required this.id,
    required this.title,
    required this.updatedLabel,
    required this.selected,
  });

  final String id;
  final String title;
  final String updatedLabel;
  final bool selected;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeConversationSessionProjection &&
          other.id == id &&
          other.title == title &&
          other.updatedLabel == updatedLabel &&
          other.selected == selected;

  @override
  int get hashCode => Object.hash(id, title, updatedLabel, selected);
}

final class NativeConversationAgentCatalogProjection {
  NativeConversationAgentCatalogProjection({
    required this.agentId,
    required Iterable<AgentConversationSession> sessions,
  }) : sessions = immutablePresentationList(sessions);

  final String agentId;
  final List<AgentConversationSession> sessions;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeConversationAgentCatalogProjection &&
          other.agentId == agentId &&
          samePresentationList(other.sessions, sessions);

  @override
  int get hashCode => Object.hash(agentId, Object.hashAll(sessions));
}

final class NativeConversationCatalogProjection {
  NativeConversationCatalogProjection({
    required Iterable<NativeConversationSessionProjection> sessions,
    Iterable<AgentConversationSession> nativeSessions =
        const <AgentConversationSession>[],
    Iterable<NativeConversationAgentCatalogProjection> agentCatalogs =
        const <NativeConversationAgentCatalogProjection>[],
    Iterable<String> runningSessionIds = const <String>[],
    this.loadingMore = false,
    this.messagePageLoading = false,
    this.messagePageError = '',
    this.preparingNewConversation = false,
    this.authorizingRuntime = false,
    this.pendingPermissionRetryTool = '',
    this.supportsLicoProfile = false,
    this.selectedLicoProfile = '',
    this.supportsImages = false,
    this.opencodeServeStatus = '',
    this.opencodeServePort,
    this.opencodeServePortConflict = false,
    required this.hasMore,
    required this.phase,
    this.notice,
  }) : sessions = immutablePresentationList(sessions),
       nativeSessions = immutablePresentationList(nativeSessions),
       agentCatalogs = immutablePresentationList(agentCatalogs),
       runningSessionIds = immutablePresentationList(runningSessionIds);

  final List<NativeConversationSessionProjection> sessions;
  final List<AgentConversationSession> nativeSessions;
  final List<NativeConversationAgentCatalogProjection> agentCatalogs;
  final List<String> runningSessionIds;
  final bool loadingMore;
  final bool messagePageLoading;
  final String messagePageError;
  final bool preparingNewConversation;
  final bool authorizingRuntime;
  final String pendingPermissionRetryTool;
  final bool supportsLicoProfile;
  final String selectedLicoProfile;
  final bool supportsImages;
  final String opencodeServeStatus;
  final int? opencodeServePort;
  final bool opencodeServePortConflict;
  final bool hasMore;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeConversationCatalogProjection &&
          samePresentationList(other.sessions, sessions) &&
          samePresentationList(other.nativeSessions, nativeSessions) &&
          samePresentationList(other.agentCatalogs, agentCatalogs) &&
          samePresentationList(other.runningSessionIds, runningSessionIds) &&
          other.loadingMore == loadingMore &&
          other.messagePageLoading == messagePageLoading &&
          other.messagePageError == messagePageError &&
          other.preparingNewConversation == preparingNewConversation &&
          other.authorizingRuntime == authorizingRuntime &&
          other.pendingPermissionRetryTool == pendingPermissionRetryTool &&
          other.supportsLicoProfile == supportsLicoProfile &&
          other.selectedLicoProfile == selectedLicoProfile &&
          other.supportsImages == supportsImages &&
          other.opencodeServeStatus == opencodeServeStatus &&
          other.opencodeServePort == opencodeServePort &&
          other.opencodeServePortConflict == opencodeServePortConflict &&
          other.hasMore == hasMore &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hashAll([
    Object.hashAll(sessions),
    Object.hashAll(nativeSessions),
    Object.hashAll(agentCatalogs),
    Object.hashAll(runningSessionIds),
    loadingMore,
    messagePageLoading,
    messagePageError,
    preparingNewConversation,
    authorizingRuntime,
    pendingPermissionRetryTool,
    supportsLicoProfile,
    selectedLicoProfile,
    supportsImages,
    opencodeServeStatus,
    opencodeServePort,
    opencodeServePortConflict,
    hasMore,
    phase,
    notice,
  ]);
}

final class ConversationPartProjection {
  const ConversationPartProjection({
    required this.id,
    required this.kind,
    required this.content,
    required this.collapsed,
  });

  final String id;
  final ConversationPartKind kind;
  final String content;
  final bool collapsed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationPartProjection &&
          other.id == id &&
          other.kind == kind &&
          other.content == content &&
          other.collapsed == collapsed;

  @override
  int get hashCode => Object.hash(id, kind, content, collapsed);
}

final class CanonicalConversationEventProjection {
  CanonicalConversationEventProjection({
    required this.id,
    required this.sequence,
    required this.authorLabel,
    required Iterable<ConversationPartProjection> parts,
    required this.finalized,
    required this.sendStateLabel,
  }) : parts = immutablePresentationList(parts);

  final String id;
  final int sequence;
  final String authorLabel;
  final List<ConversationPartProjection> parts;
  final bool finalized;
  final String sendStateLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanonicalConversationEventProjection &&
          other.id == id &&
          other.sequence == sequence &&
          other.authorLabel == authorLabel &&
          samePresentationList(other.parts, parts) &&
          other.finalized == finalized &&
          other.sendStateLabel == sendStateLabel;

  @override
  int get hashCode => Object.hash(
    id,
    sequence,
    authorLabel,
    Object.hashAll(parts),
    finalized,
    sendStateLabel,
  );
}

final class CanonicalConversationProjection {
  CanonicalConversationProjection({
    required this.conversationId,
    required Iterable<CanonicalConversationEventProjection> events,
    this.conversation,
    Iterable<ClientConversationEvent> canonicalEvents =
        const <ClientConversationEvent>[],
    Iterable<String> recentParticipantAgentIds = const <String>[],
    Iterable<ClientConversationSummary> groupConversations =
        const <ClientConversationSummary>[],
    Iterable<ConversationParticipantRuntimeProjection>
        participantRuntimeProfiles =
        const <ConversationParticipantRuntimeProjection>[],
    Map<String, ProviderQuotaSnapshot> quotaSnapshots =
        const <String, ProviderQuotaSnapshot>{},
    this.assistantModel = '',
    this.assistantReasoningEffort = '',
    this.failureStage = '',
    this.failureRef = '',
    this.failureRecovery = '',
    this.failureCopyBlob = '',
    this.sending = false,
    this.dispatchPending = false,
    required this.hasEarlier,
    required this.phase,
    this.notice,
  }) : events = immutablePresentationList(events),
       canonicalEvents = immutablePresentationList(canonicalEvents),
       recentParticipantAgentIds = immutablePresentationList(
         recentParticipantAgentIds,
       ),
       groupConversations = immutablePresentationList(groupConversations),
       participantRuntimeProfiles = immutablePresentationList(
         participantRuntimeProfiles,
       ),
       quotaSnapshots = Map<String, ProviderQuotaSnapshot>.unmodifiable(
         quotaSnapshots,
       );

  final String conversationId;
  final List<CanonicalConversationEventProjection> events;
  final ClientConversation? conversation;
  final List<ClientConversationEvent> canonicalEvents;
  final List<String> recentParticipantAgentIds;
  final List<ClientConversationSummary> groupConversations;
  final List<ConversationParticipantRuntimeProjection>
  participantRuntimeProfiles;
  final Map<String, ProviderQuotaSnapshot> quotaSnapshots;
  final String assistantModel;
  final String assistantReasoningEffort;
  final String failureStage;
  final String failureRef;
  final String failureRecovery;
  final String failureCopyBlob;
  final bool sending;
  final bool dispatchPending;
  final bool hasEarlier;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanonicalConversationProjection &&
          other.conversationId == conversationId &&
          samePresentationList(other.events, events) &&
          identical(other.conversation, conversation) &&
          samePresentationList(other.canonicalEvents, canonicalEvents) &&
          samePresentationList(
            other.recentParticipantAgentIds,
            recentParticipantAgentIds,
          ) &&
          samePresentationList(other.groupConversations, groupConversations) &&
          samePresentationList(
            other.participantRuntimeProfiles,
            participantRuntimeProfiles,
          ) &&
          _sameQuotaSnapshots(other.quotaSnapshots, quotaSnapshots) &&
          other.assistantModel == assistantModel &&
          other.assistantReasoningEffort == assistantReasoningEffort &&
          other.failureStage == failureStage &&
          other.failureRef == failureRef &&
          other.failureRecovery == failureRecovery &&
          other.failureCopyBlob == failureCopyBlob &&
          other.sending == sending &&
          other.dispatchPending == dispatchPending &&
          other.hasEarlier == hasEarlier &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hashAll([
    conversationId,
    Object.hashAll(events),
    conversation,
    Object.hashAll(canonicalEvents),
    Object.hashAll(recentParticipantAgentIds),
    Object.hashAll(groupConversations),
    Object.hashAll(participantRuntimeProfiles),
    Object.hashAll(
      quotaSnapshots.entries.map(
        (entry) => Object.hash(entry.key, entry.value),
      ),
    ),
    assistantModel,
    assistantReasoningEffort,
    failureStage,
    failureRef,
    failureRecovery,
    failureCopyBlob,
    sending,
    dispatchPending,
    hasEarlier,
    phase,
    notice,
  ]);
}

final class ConversationParticipantRuntimeProjection {
  const ConversationParticipantRuntimeProjection({
    required this.agentId,
    required this.model,
    required this.reasoningEffort,
  });

  final String agentId;
  final String model;
  final String reasoningEffort;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationParticipantRuntimeProjection &&
          other.agentId == agentId &&
          other.model == model &&
          other.reasoningEffort == reasoningEffort;

  @override
  int get hashCode => Object.hash(agentId, model, reasoningEffort);
}

bool _sameQuotaSnapshots(
  Map<String, ProviderQuotaSnapshot> left,
  Map<String, ProviderQuotaSnapshot> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

final class MembershipTurnProjection {
  MembershipTurnProjection({
    required this.membershipId,
    required this.agentLabel,
    required this.phase,
    required this.inputEnabled,
    required Iterable<ConversationPartProjection> liveParts,
    Iterable<AgentConversationMessage> messages =
        const <AgentConversationMessage>[],
    this.turnHandle = '',
    this.participantAgentId = '',
    this.participantRole = '',
    this.cancelEnabled = false,
    this.failureReasonCode = '',
  }) : liveParts = immutablePresentationList(liveParts),
       messages = immutablePresentationList(messages);

  final String membershipId;
  final String agentLabel;
  final PersistentTurnPhase phase;
  final bool inputEnabled;
  final List<ConversationPartProjection> liveParts;
  final List<AgentConversationMessage> messages;
  final String turnHandle;
  final String participantAgentId;
  final String participantRole;
  final bool cancelEnabled;
  final String failureReasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MembershipTurnProjection &&
          other.membershipId == membershipId &&
          other.agentLabel == agentLabel &&
          other.phase == phase &&
          other.inputEnabled == inputEnabled &&
          samePresentationList(other.liveParts, liveParts) &&
          samePresentationList(other.messages, messages) &&
          other.turnHandle == turnHandle &&
          other.participantAgentId == participantAgentId &&
          other.participantRole == participantRole &&
          other.cancelEnabled == cancelEnabled &&
          other.failureReasonCode == failureReasonCode;

  @override
  int get hashCode => Object.hash(
    membershipId,
    agentLabel,
    phase,
    inputEnabled,
    Object.hashAll(liveParts),
    Object.hashAll(messages),
    turnHandle,
    participantAgentId,
    participantRole,
    cancelEnabled,
    failureReasonCode,
  );
}

final class PersistentTurnProjection {
  PersistentTurnProjection({
    required this.conversationId,
    required Iterable<MembershipTurnProjection> memberships,
  }) : memberships = immutablePresentationList(memberships);

  final String conversationId;
  final List<MembershipTurnProjection> memberships;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersistentTurnProjection &&
          other.conversationId == conversationId &&
          samePresentationList(other.memberships, memberships);

  @override
  int get hashCode => Object.hash(conversationId, Object.hashAll(memberships));
}

final class ComposerProjection {
  ComposerProjection({
    required this.conversationId,
    required this.draft,
    required this.inputEnabled,
    required this.sendLabel,
    Iterable<String> modelOptions = const <String>[],
    this.selectedModel = '',
    this.defaultModel = '',
    Iterable<String> reasoningEffortOptions = const <String>[],
    this.selectedReasoningEffort = '',
    this.defaultReasoningEffort = '',
    this.workingDirectory = '',
    this.workingDirectorySelectable = false,
  }) : modelOptions = immutablePresentationList(modelOptions),
       reasoningEffortOptions = immutablePresentationList(
         reasoningEffortOptions,
       );

  final String conversationId;
  final String draft;
  final bool inputEnabled;
  final String sendLabel;
  final List<String> modelOptions;
  final String selectedModel;
  final String defaultModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final String defaultReasoningEffort;
  final String workingDirectory;
  final bool workingDirectorySelectable;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComposerProjection &&
          other.conversationId == conversationId &&
          other.draft == draft &&
          other.inputEnabled == inputEnabled &&
          other.sendLabel == sendLabel &&
          samePresentationList(other.modelOptions, modelOptions) &&
          other.selectedModel == selectedModel &&
          other.defaultModel == defaultModel &&
          samePresentationList(
            other.reasoningEffortOptions,
            reasoningEffortOptions,
          ) &&
          other.selectedReasoningEffort == selectedReasoningEffort &&
          other.defaultReasoningEffort == defaultReasoningEffort &&
          other.workingDirectory == workingDirectory &&
          other.workingDirectorySelectable == workingDirectorySelectable;

  @override
  int get hashCode => Object.hashAll([
    conversationId,
    draft,
    inputEnabled,
    sendLabel,
    Object.hashAll(modelOptions),
    selectedModel,
    defaultModel,
    Object.hashAll(reasoningEffortOptions),
    selectedReasoningEffort,
    defaultReasoningEffort,
    workingDirectory,
    workingDirectorySelectable,
  ]);
}

final class ConversationAttachmentProjection {
  const ConversationAttachmentProjection({
    required this.id,
    required this.displayName,
    required this.mediaKind,
    required this.stateLabel,
    this.localPath = '',
    this.dataBase64 = '',
  });

  final String id;
  final String displayName;
  final String mediaKind;
  final String stateLabel;
  final String localPath;
  final String dataBase64;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationAttachmentProjection &&
          other.id == id &&
          other.displayName == displayName &&
          other.mediaKind == mediaKind &&
          other.stateLabel == stateLabel &&
          other.localPath == localPath &&
          other.dataBase64 == dataBase64;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    mediaKind,
    stateLabel,
    localPath,
    dataBase64,
  );
}

final class ConversationAttachmentsProjection {
  ConversationAttachmentsProjection({
    required this.conversationId,
    required Iterable<ConversationAttachmentProjection> attachments,
    required this.acceptsImages,
    this.statusCode = '',
  }) : attachments = immutablePresentationList(attachments);

  final String conversationId;
  final List<ConversationAttachmentProjection> attachments;
  final bool acceptsImages;
  final String statusCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationAttachmentsProjection &&
          other.conversationId == conversationId &&
          samePresentationList(other.attachments, attachments) &&
          other.acceptsImages == acceptsImages &&
          other.statusCode == statusCode;

  @override
  int get hashCode => Object.hash(
    conversationId,
    Object.hashAll(attachments),
    acceptsImages,
    statusCode,
  );
}

final class ConversationTabActivityProjection {
  ConversationTabActivityProjection({
    required this.conversationId,
    required this.active,
    required this.unreadCount,
    required this.requiresAttention,
    Iterable<ConversationAgentActivityProjection> agentActivities =
        const <ConversationAgentActivityProjection>[],
  }) : agentActivities = immutablePresentationList(agentActivities);

  final String conversationId;
  final bool active;
  final int unreadCount;
  final bool requiresAttention;
  final List<ConversationAgentActivityProjection> agentActivities;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationTabActivityProjection &&
          other.conversationId == conversationId &&
          other.active == active &&
          other.unreadCount == unreadCount &&
          other.requiresAttention == requiresAttention &&
          samePresentationList(other.agentActivities, agentActivities);

  @override
  int get hashCode => Object.hash(
    conversationId,
    active,
    unreadCount,
    requiresAttention,
    Object.hashAll(agentActivities),
  );
}

final class ConversationAgentActivityProjection {
  const ConversationAgentActivityProjection({
    required this.agentId,
    required this.activity,
  });

  final String agentId;
  final AgentConversationTabActivity activity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationAgentActivityProjection &&
          other.agentId == agentId &&
          other.activity == activity;

  @override
  int get hashCode => Object.hash(agentId, activity);
}

final class ConversationNotificationsProjection {
  ConversationNotificationsProjection({
    required Iterable<PresentationNotice> notices,
  }) : notices = immutablePresentationList(notices);

  final List<PresentationNotice> notices;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationNotificationsProjection &&
          samePresentationList(other.notices, notices);

  @override
  int get hashCode => Object.hashAll(notices);
}

final class ArchivedConversationItemProjection {
  const ArchivedConversationItemProjection({
    required this.id,
    required this.title,
    required this.destinationLabel,
  });

  final String id;
  final String title;
  final String destinationLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ArchivedConversationItemProjection &&
          other.id == id &&
          other.title == title &&
          other.destinationLabel == destinationLabel;

  @override
  int get hashCode => Object.hash(id, title, destinationLabel);
}

final class ConversationArchiveDestinationProjection {
  const ConversationArchiveDestinationProjection({
    required this.sourceAgentId,
    required this.allDestination,
    required this.exactKeywordDestination,
  });

  final String sourceAgentId;
  final String allDestination;
  final String exactKeywordDestination;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationArchiveDestinationProjection &&
          other.sourceAgentId == sourceAgentId &&
          other.allDestination == allDestination &&
          other.exactKeywordDestination == exactKeywordDestination;

  @override
  int get hashCode =>
      Object.hash(sourceAgentId, allDestination, exactKeywordDestination);
}

final class ConversationArchiveProjection {
  ConversationArchiveProjection({
    required Iterable<ArchivedConversationItemProjection> conversations,
    required this.phase,
    this.queryDraft = '',
    this.backupInProgress = false,
    Iterable<ConversationArchiveDestinationProjection> backupDestinations =
        const <ConversationArchiveDestinationProjection>[],
    this.notice,
  }) : conversations = immutablePresentationList(conversations),
       backupDestinations = immutablePresentationList(backupDestinations);

  final List<ArchivedConversationItemProjection> conversations;
  final PresentationPhase phase;
  final String queryDraft;
  final bool backupInProgress;
  final List<ConversationArchiveDestinationProjection> backupDestinations;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationArchiveProjection &&
          samePresentationList(other.conversations, conversations) &&
          other.phase == phase &&
          other.queryDraft == queryDraft &&
          other.backupInProgress == backupInProgress &&
          samePresentationList(other.backupDestinations, backupDestinations) &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(conversations),
    phase,
    queryDraft,
    backupInProgress,
    Object.hashAll(backupDestinations),
    notice,
  );
}
