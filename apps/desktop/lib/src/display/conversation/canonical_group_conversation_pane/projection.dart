import 'package:licoup/src/projections/conversation/canonical_group_event_metadata_parser.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/shared/l10n/lico_strings_catalog.dart';

String _iso(int unixMs) => unixMs <= 0
    ? ''
    : DateTime.fromMillisecondsSinceEpoch(
        unixMs,
        isUtc: true,
      ).toIso8601String();

List<TargetCandidate> resolveCanonicalGroupParticipantTargets(
  ClientConversation conversation,
  List<TargetCandidate> targets,
) {
  final resolved = <TargetCandidate>[];
  for (final membership in conversation.activeAgentMemberships) {
    final agentId = membership.principal.agentId.trim();
    TargetCandidate? target;
    for (final candidate in targets) {
      if (candidate.target == agentId || candidate.id == agentId) {
        target = candidate;
        break;
      }
    }
    resolved.add(
      target ??
          TargetCandidate(
            target: agentId,
            label: membership.principal.displayName.trim().isEmpty
                ? agentId
                : membership.principal.displayName.trim(),
            kind: 'conversation-member',
            status: TargetCandidateStatus.synthesizedMembership,
            configured: false,
            confidence: 1,
            adapterStatus: 'runtime-unavailable',
            scanSource: 'canonical-conversation',
          ),
    );
  }
  return List<TargetCandidate>.unmodifiable(resolved);
}

List<TargetCandidate> resolveCanonicalGroupOrderedParticipantTargets(
  ClientConversation conversation,
  List<TargetCandidate> targets,
  List<String> orderedAgentIds,
) {
  if (orderedAgentIds.isEmpty) return const [];
  final targetByAgentId = {
    for (final target in targets) target.target: target,
    for (final target in targets) target.id: target,
  };
  final membershipByAgentId = {
    for (final membership in conversation.activeAgentMemberships)
      membership.principal.agentId: membership,
  };
  final resolved = <TargetCandidate>[];
  for (final agentId in orderedAgentIds) {
    final target = targetByAgentId[agentId];
    if (target != null) {
      resolved.add(target);
    } else {
      final membership = membershipByAgentId[agentId];
      if (membership != null) {
        resolved.add(
          TargetCandidate(
            target: agentId,
            label: membership.principal.displayName.trim().isEmpty
                ? agentId
                : membership.principal.displayName.trim(),
            kind: 'conversation-member',
            status: TargetCandidateStatus.synthesizedMembership,
            configured: false,
            confidence: 1,
            adapterStatus: 'runtime-unavailable',
            scanSource: 'canonical-conversation',
          ),
        );
      }
    }
  }
  return List<TargetCandidate>.unmodifiable(resolved);
}

ClientConversationMembership? canonicalGroupAgentMembership(
  ClientConversation conversation,
  TargetCandidate target,
) {
  for (final membership in conversation.activeAgentMemberships) {
    final agentId = membership.principal.agentId;
    if (agentId == target.target || agentId == target.id) return membership;
  }
  return null;
}

AgentConversationSession canonicalGroupConversationSession(
  ClientConversation conversation,
  List<ClientConversationEvent> events,
  LicoStrings strings,
) {
  final memberships = {
    for (final membership in conversation.memberships)
      membership.id: membership,
  };
  final membershipsByPrincipal = {
    for (final membership in conversation.memberships)
      membership.principal.id: membership,
  };
  final messages = <AgentConversationMessage>[];
  for (final event in events) {
    final author = memberships[event.authorMembershipId];
    if (event.kind != ConversationEventKind.message) {
      final presentation = _canonicalGroupEventPresentation(
        event,
        memberships: memberships,
        membershipsByPrincipal: membershipsByPrincipal,
        strings: strings,
      );
      messages.add(
        AgentConversationMessage(
          id: event.id,
          role: 'event',
          text: presentation.detail,
          createdAt: _iso(event.createdAtUnixMs),
          layer: AgentConversationSemanticLayer.execution,
          cardType: event.kind.wireName,
          cardTitle: presentation.title,
          stableIdentity: event.id,
        ),
      );
      continue;
    }
    final user = author?.principal.kind == ConversationPrincipalKind.human;
    final participantRole = user
        ? ''
        : (author != null && author.id == conversation.assistantMembershipId
              ? 'assistant'
              : 'member');
    final textChunks = <String>[];
    var textCreatedAt = event.createdAtUnixMs;
    var textFlush = 0;
    void flushText() {
      if (textChunks.isEmpty) return;
      messages.add(
        AgentConversationMessage(
          id: textFlush == 0 ? event.id : '${event.id}:text:$textFlush',
          role: user ? 'user' : 'assistant',
          text: textChunks.join(),
          createdAt: _iso(textCreatedAt),
          layer: AgentConversationSemanticLayer.thread,
          stableIdentity: event.id,
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
        ),
      );
      textChunks.clear();
      textFlush += 1;
    }

    for (final eventPart in event.parts) {
      if (eventPart.kind == ConversationEventPartKind.text) {
        if (textChunks.isEmpty && eventPart.createdAtUnixMs != 0) {
          textCreatedAt = eventPart.createdAtUnixMs;
        }
        textChunks.add(eventPart.content);
        continue;
      }
      flushText();
      final presentation = _canonicalGroupPartPresentation(eventPart);
      messages.add(
        AgentConversationMessage(
          id: eventPart.id.isEmpty
              ? '${event.id}:${eventPart.ordinal}'
              : eventPart.id,
          role: user ? 'user' : presentation.cardType,
          text: presentation.text,
          createdAt: _iso(
            eventPart.createdAtUnixMs == 0
                ? event.createdAtUnixMs
                : eventPart.createdAtUnixMs,
          ),
          layer: AgentConversationSemanticLayer.execution,
          cardType: presentation.cardType,
          cardTitle: presentation.cardTitle,
          stableIdentity: event.id,
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
        ),
      );
    }
    flushText();
  }
  return AgentConversationSession(
    id: conversation.id,
    agentId: conversation.activeAgentMemberships.isEmpty
        ? ''
        : conversation.activeAgentMemberships.first.principal.agentId,
    title: conversation.title,
    createdAt: _iso(conversation.createdAtUnixMs),
    updatedAt: _iso(conversation.updatedAtUnixMs),
    messages: List<AgentConversationMessage>.unmodifiable(messages),
    nativeSessionId: conversation.id,
    adapterId: 'canonical-conversation',
    sourceKind: 'canonical-conversation',
    sourceClient: 'licoup',
    sourceClientLabel: 'LicoUp',
    native: false,
    readOnly: false,
    messageCount: conversation.eventCount,
    sourceMessageCount: conversation.eventCount,
    historyTruncated: conversation.eventCount > events.length,
  );
}

({String cardType, String cardTitle, String text})
_canonicalGroupPartPresentation(ClientConversationEventPart eventPart) {
  final lifecycleStage = CanonicalGroupEventMetadataParser.lifecycleStage(
    eventPart,
  );
  if (lifecycleStage != null) {
    return (
      cardType: 'lifecycle',
      cardTitle: 'lifecycle.$lifecycleStage',
      text: lifecycleStage,
    );
  }
  final cardType = switch (eventPart.kind) {
    ConversationEventPartKind.text => '',
    ConversationEventPartKind.reasoning => 'reasoning',
    ConversationEventPartKind.toolCall => 'tool-call',
    ConversationEventPartKind.toolResult => 'tool-result',
    ConversationEventPartKind.artifact => 'artifact',
    ConversationEventPartKind.diagnostic => 'diagnostic',
    ConversationEventPartKind.metadata => 'metadata',
    ConversationEventPartKind.unknown => 'event',
  };
  return (cardType: cardType, cardTitle: '', text: eventPart.content);
}

({String title, String detail}) _canonicalGroupEventPresentation(
  ClientConversationEvent event, {
  required Map<String, ClientConversationMembership> memberships,
  required Map<String, ClientConversationMembership> membershipsByPrincipal,
  required LicoStrings strings,
}) {
  final membershipEvent = event.kind == ConversationEventKind.membershipChanged;
  final title = membershipEvent
      ? strings.groupConversationMembershipChangeTitle
      : strings.groupConversationAvailabilityChangeTitle;
  final metadata = _canonicalGroupEventMetadata(event);
  if (metadata == null) {
    return (
      title: title,
      detail: strings.groupConversationEventDetailsUnavailable,
    );
  }
  final membershipId = (metadata['membershipId'] ?? '').toString().trim();
  final principalId = (metadata['principalId'] ?? '').toString().trim();
  final membership =
      memberships[membershipId] ?? membershipsByPrincipal[principalId];
  final memberLabel = _canonicalGroupEventMemberLabel(
    metadata,
    membership: membership,
    strings: strings,
  );

  if (membershipEvent) {
    final change = (metadata['change'] ?? '').toString().trim();
    final detail = switch (change) {
      'joined' => strings.groupConversationMemberJoined(memberLabel),
      'left' => strings.groupConversationMemberLeft(memberLabel),
      'access-set' => strings.groupConversationMemberAccessSet(
        memberLabel,
        strings.groupConversationAccessLabel(
          (metadata['access'] ?? '').toString(),
        ),
      ),
      _ => strings.groupConversationMemberChangeUnknown(memberLabel),
    };
    return (title: title, detail: detail);
  }

  final availability = strings.groupConversationAvailabilityLabel(
    (metadata['availability'] ?? '').toString(),
  );
  return (
    title: title,
    detail: strings.groupConversationMemberAvailabilitySet(
      memberLabel,
      availability,
    ),
  );
}

Map<String, dynamic>? _canonicalGroupEventMetadata(
  ClientConversationEvent event,
) {
  return CanonicalGroupEventMetadataParser.eventMetadata(event);
}

String _canonicalGroupEventMemberLabel(
  Map<String, dynamic> metadata, {
  required ClientConversationMembership? membership,
  required LicoStrings strings,
}) {
  final embedded = (metadata['displayName'] ?? '').toString().trim();
  if (embedded.isNotEmpty) return embedded;
  final principal = membership?.principal;
  final displayName = principal?.displayName.trim() ?? '';
  if (displayName.isNotEmpty) return displayName;
  final agentId = principal?.agentId.trim() ?? '';
  if (agentId.isNotEmpty) return agentId;
  final principalId = (metadata['principalId'] ?? '').toString().trim();
  if (principalId.isNotEmpty) return principalId;
  final membershipId = (metadata['membershipId'] ?? '').toString().trim();
  if (membershipId.isNotEmpty) return membershipId;
  return strings.groupConversationUnknownMember;
}
