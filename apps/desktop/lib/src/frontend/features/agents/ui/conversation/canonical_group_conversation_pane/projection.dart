import 'dart:convert';

import 'package:licoup/src/contracts/conversation_execution.dart';

import 'package:licoup/src/presentation/conversation/canonical_conversation_event_metadata.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';

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
  final failedSourceEventIds = {
    for (final event in events)
      if (event.finalized &&
          event.causationId.trim().isNotEmpty &&
          event.parts.any(_isFailureDiagnosticPart))
        event.causationId.trim(),
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
    final correlationId = event.correlationId.trim();
    final turnIdentity = correlationId.isEmpty ? '' : correlationId;
    final executionReference = !user && correlationId.isNotEmpty
        ? ConversationExecutionReference(
            conversationId: event.conversationId,
            membershipId: event.authorMembershipId,
            turnHandle: correlationId,
          )
        : null;
    var processIndex = 0;
    final textChunks = <String>[];
    // Posted image Event Parts collect here and land on the flushed text
    // message as typed attachments — the same message shape the pending
    // composer draft renders. An image-only post flushes no text, so its
    // images close the event as a standalone message instead.
    final pendingImages = <AgentConversationImageAttachment>[];
    var completedSnapshotPending = false;
    var completedSnapshotBase = '';
    var insideMessageUnit = false;
    var textCreatedAt = event.createdAtUnixMs;
    var textFlush = 0;
    AgentConversationReplyTerminalState? terminalState;
    void flushText() {
      if (textChunks.isEmpty) return;
      final text = textChunks.join();
      if (text.trim().isEmpty && pendingImages.isEmpty) {
        textChunks.clear();
        return;
      }
      final identity = textFlush == 0
          ? (executionReference == null ? event.id : '$correlationId-assistant')
          : '${event.id}:text:$textFlush';
      messages.add(
        AgentConversationMessage(
          id: identity,
          role: user ? 'user' : 'assistant',
          text: text,
          createdAt: _iso(textCreatedAt),
          layer: AgentConversationSemanticLayer.thread,
          stableIdentity: identity,
          images: List<AgentConversationImageAttachment>.unmodifiable(
            pendingImages,
          ),
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
          executionReference: executionReference,
          deliveryState: user && failedSourceEventIds.contains(event.id)
              ? AgentConversationMessageDeliveryState.failed
              : AgentConversationMessageDeliveryState.ordinary,
        ),
      );
      textChunks.clear();
      pendingImages.clear();
      completedSnapshotPending = false;
      textFlush += 1;
    }

    for (final eventPart in event.parts) {
      if (_isCanonicalRuntimeReplayPart(eventPart)) {
        continue;
      }
      if (eventPart.kind == ConversationEventPartKind.image) {
        final attachment = _canonicalGroupImageAttachment(eventPart);
        if (attachment != null) {
          pendingImages.add(attachment);
          continue;
        }
        // Unreadable attachment metadata keeps the generic card fallback so
        // the part still surfaces instead of vanishing.
      }
      if (eventPart.kind == ConversationEventPartKind.text) {
        if (completedSnapshotPending &&
            eventPart.content == completedSnapshotBase) {
          completedSnapshotPending = false;
          continue;
        }
        completedSnapshotPending = false;
        if (textChunks.isEmpty && eventPart.createdAtUnixMs != 0) {
          textCreatedAt = eventPart.createdAtUnixMs;
        }
        textChunks.add(eventPart.content);
        continue;
      }
      if (_canonicalMessageUnit(eventPart) != null) {
        flushText();
        completedSnapshotPending = false;
        insideMessageUnit = true;
        continue;
      }
      var presentation = _canonicalGroupPartPresentation(eventPart);
      if (presentation.cardType == 'lifecycle') {
        terminalState = switch (presentation.text) {
          'completed' => AgentConversationReplyTerminalState.completed,
          'failed' => AgentConversationReplyTerminalState.failed,
          'cancelled' => AgentConversationReplyTerminalState.cancelled,
          _ => terminalState,
        };
      }
      if (presentation.cardType == 'continuity-task-card') {
        try {
          final decoded = jsonDecode(presentation.text);
          if (decoded is Map) {
            decoded['sequence'] = event.sequence;
            presentation = (
              cardType: presentation.cardType,
              cardTitle: presentation.cardTitle,
              text: jsonEncode(decoded),
            );
          }
        } on Object {
          // Keep the stored part text when the metadata is not an object.
        }
      }
      if (!insideMessageUnit && presentation.cardType != 'lifecycle') {
        flushText();
      }
      if (presentation.cardTitle == 'lifecycle.completed') {
        completedSnapshotPending = true;
        completedSnapshotBase = textChunks.join();
      }
      final stableIdentity = turnIdentity.isEmpty
          ? event.id
          : presentation.cardType == 'lifecycle'
          ? '$turnIdentity-lifecycle'
          : '$turnIdentity-process-${processIndex++}';
      messages.add(
        AgentConversationMessage(
          id: eventPart.id.isEmpty
              ? '${event.id}:${eventPart.ordinal}'
              : eventPart.id,
          role: user
              ? 'user'
              : presentation.cardTitle == 'lifecycle.failed'
              ? 'error'
              : presentation.cardType,
          text: presentation.text,
          createdAt: _iso(
            eventPart.createdAtUnixMs == 0
                ? event.createdAtUnixMs
                : eventPart.createdAtUnixMs,
          ),
          layer: AgentConversationSemanticLayer.execution,
          cardType: presentation.cardType,
          cardTitle: presentation.cardTitle,
          stableIdentity: stableIdentity,
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
          executionReference: executionReference,
          deliveryState: user && failedSourceEventIds.contains(event.id)
              ? AgentConversationMessageDeliveryState.failed
              : AgentConversationMessageDeliveryState.ordinary,
        ),
      );
    }
    flushText();
    if (!user &&
        event.finalized &&
        textFlush == 0 &&
        pendingImages.isEmpty &&
        terminalState != null) {
      final identity = executionReference == null
          ? event.id
          : '$correlationId-assistant';
      messages.add(
        AgentConversationMessage(
          id: identity,
          role: 'assistant',
          text: '',
          createdAt: _iso(event.createdAtUnixMs),
          stableIdentity: identity,
          participantAgentId: author?.principal.agentId.trim() ?? '',
          participantLabel: author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
          executionReference: executionReference,
          replyTerminalState: terminalState,
        ),
      );
    }
    if (pendingImages.isNotEmpty) {
      final identity = executionReference == null
          ? event.id
          : '$correlationId-assistant';
      messages.add(
        AgentConversationMessage(
          id: identity,
          role: user ? 'user' : 'assistant',
          text: '',
          createdAt: _iso(event.createdAtUnixMs),
          layer: AgentConversationSemanticLayer.thread,
          stableIdentity: identity,
          images: List<AgentConversationImageAttachment>.unmodifiable(
            pendingImages,
          ),
          participantAgentId: user
              ? ''
              : author?.principal.agentId.trim() ?? '',
          participantLabel: user
              ? ''
              : author?.principal.displayName.trim() ?? '',
          participantRole: participantRole,
          executionReference: executionReference,
        ),
      );
      pendingImages.clear();
    }
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

/// Live PersistentTurn frames may still carry the submitted-user-message
/// delta. Canonical Events already own human speech, so group live turns
/// keep only agent content. When the live list has no user rows, the same
/// instance is returned so the pane's identity cache still holds.
List<AgentConversationMessage> canonicalGroupLiveTurnMessages(
  List<AgentConversationMessage> live,
) {
  final hasUser = live.any(
    (message) => message.role.trim().toLowerCase() == 'user',
  );
  if (!hasUser) return live;
  return [
    for (final message in live)
      if (message.role.trim().toLowerCase() != 'user') message,
  ];
}

/// Legacy mixed-turn Events stored the submitted-user-message observer
/// delta as a metadata Part on the agent Event. It is not a visible Part.
bool _isCanonicalRuntimeReplayPart(ClientConversationEventPart part) {
  if (part.kind != ConversationEventPartKind.metadata) return false;
  try {
    final decoded = jsonDecode(part.content);
    if (decoded is! Map) return false;
    return (decoded['event'] ?? '').toString().trim() ==
        'conversation.user.message';
  } catch (_) {
    return false;
  }
}

bool _isFailureDiagnosticPart(ClientConversationEventPart part) {
  if (part.kind != ConversationEventPartKind.diagnostic) return false;
  try {
    final decoded = jsonDecode(part.content);
    return decoded is Map &&
        (decoded['code'] ?? '').toString().trim().isNotEmpty;
  } catch (_) {
    return false;
  }
}

String? _canonicalMessageUnit(ClientConversationEventPart part) {
  if (part.kind != ConversationEventPartKind.metadata) return null;
  try {
    final decoded = jsonDecode(part.content);
    if (decoded is! Map) return null;
    final value = (decoded['messageUnit'] ?? '').toString().trim();
    return value.isEmpty ? null : value;
  } catch (_) {
    return null;
  }
}

/// Decode one image Event Part's content into the typed message attachment.
/// Returns null for malformed content so the caller keeps the generic card
/// fallback, mirroring the store's tolerant reader.
AgentConversationImageAttachment? _canonicalGroupImageAttachment(
  ClientConversationEventPart part,
) {
  try {
    final decoded = jsonDecode(part.content);
    if (decoded is! Map) return null;
    final path = (decoded['path'] ?? '').toString().trim();
    if (path.isEmpty) return null;
    return AgentConversationImageAttachment(
      mediaType: (decoded['mediaType'] ?? '').toString().trim(),
      filePath: path,
      name: (decoded['name'] ?? '').toString().trim(),
    );
  } catch (_) {
    return null;
  }
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
  if (_isFailureDiagnosticPart(eventPart)) {
    final decoded = jsonDecode(eventPart.content) as Map;
    final stage = (decoded['stage'] ?? '').toString();
    final code = (decoded['code'] ?? '').toString();
    final reason =
        (decoded['message'] ?? decoded['reason'] ?? decoded['turnStatus'] ?? '')
            .toString();
    return (
      cardType: 'error',
      cardTitle: code,
      text: [stage, code, reason].where((value) => value.isNotEmpty).join(': '),
    );
  }
  if (eventPart.kind == ConversationEventPartKind.metadata) {
    try {
      final decoded = jsonDecode(eventPart.content);
      if (decoded is Map) {
        final goalId = (decoded['goalId'] ?? '').toString().trim();
        final childId = (decoded['childConversationId'] ?? '')
            .toString()
            .trim();
        if (goalId.isNotEmpty && childId.isNotEmpty) {
          return (
            cardType: 'continuity-task-card',
            cardTitle: goalId,
            text: eventPart.content,
          );
        }
      }
    } on Object {
      // Keep the generic metadata card when the part is not a task card.
    }
  }
  final cardType = switch (eventPart.kind) {
    ConversationEventPartKind.text => '',
    ConversationEventPartKind.reasoning => 'reasoning',
    ConversationEventPartKind.toolCall => 'tool-call',
    ConversationEventPartKind.toolResult => 'tool-result',
    ConversationEventPartKind.artifact => 'artifact',
    ConversationEventPartKind.diagnostic => 'diagnostic',
    ConversationEventPartKind.metadata => 'metadata',
    // Well-formed image parts never reach this switch: the parts loop
    // collects them onto the message's typed attachments first.
    ConversationEventPartKind.image => 'event',
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
