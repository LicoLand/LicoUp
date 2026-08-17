import 'package:licoup/src/contracts/generated/conversation.g.dart';

final class ClientConversationSummary {
  const ClientConversationSummary({
    required this.id,
    required this.title,
    required this.archived,
    this.pinned = false,
    this.group = false,
    required this.revision,
    required this.updatedAtUnixMs,
    required this.membershipCount,
    required this.eventCount,
  });

  factory ClientConversationSummary.fromJson(Map<String, dynamic> json) =>
      ClientConversationSummary(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        archived: json['archived'] == true,
        pinned: json['pinned'] == true,
        group: json['isGroup'] == true,
        revision: _integer(json['revision']),
        updatedAtUnixMs: _integer(json['updatedAtUnixMs']),
        membershipCount: _integer(json['membershipCount']),
        eventCount: _integer(json['eventCount']),
      );

  final String id;
  final String title;
  final bool archived;
  final bool pinned;
  final bool group;
  final int revision;
  final int updatedAtUnixMs;
  final int membershipCount;
  final int eventCount;

  bool get isGroup => group;
}

final class ClientConversation {
  const ClientConversation({
    required this.id,
    required this.title,
    required this.archived,
    this.pinned = false,
    this.group = false,
    this.strategyRevision = '',
    required this.revision,
    required this.createdAtUnixMs,
    required this.updatedAtUnixMs,
    required this.memberships,
    required this.eventCount,
  });

  factory ClientConversation.fromJson(Map<String, dynamic> json) =>
      ClientConversation(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        archived: json['archived'] == true,
        pinned: json['pinned'] == true,
        group: json['isGroup'] == true,
        strategyRevision: (json['strategyRevision'] ?? '').toString(),
        revision: _integer(json['revision']),
        createdAtUnixMs: _integer(json['createdAtUnixMs']),
        updatedAtUnixMs: _integer(json['updatedAtUnixMs']),
        memberships: _maps(
          json['memberships'],
        ).map(ClientConversationMembership.fromJson).toList(growable: false),
        eventCount: _integer(json['eventCount']),
      );

  final String id;
  final String title;
  final bool archived;
  final bool pinned;
  final bool group;
  final String strategyRevision;
  final int revision;
  final int createdAtUnixMs;
  final int updatedAtUnixMs;
  final List<ClientConversationMembership> memberships;
  final int eventCount;

  bool get isDefaultLocalAgentGroup => id == 'lico-group-default';

  List<ClientConversationMembership> get activeMemberships => memberships
      .where(
        (membership) =>
            membership.status == ConversationMembershipStatus.active,
      )
      .toList(growable: false);

  List<ClientConversationMembership> get activeAgentMemberships =>
      activeMemberships
          .where(
            (membership) =>
                membership.principal.kind == ConversationPrincipalKind.agent,
          )
          .toList(growable: false);

  ClientConversationMembership? get localOwnerMembership {
    for (final membership in activeMemberships) {
      if (membership.principal.kind == ConversationPrincipalKind.human &&
          membership.access == ConversationMembershipAccess.owner) {
        return membership;
      }
    }
    return null;
  }
}

final class ClientConversationPrincipal {
  const ClientConversationPrincipal({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.agentId,
    required this.createdAtUnixMs,
  });

  factory ClientConversationPrincipal.fromJson(Map<String, dynamic> json) =>
      ClientConversationPrincipal(
        id: (json['id'] ?? '').toString(),
        kind: ConversationPrincipalKind.fromWire(json['kind']),
        displayName: (json['displayName'] ?? '').toString(),
        agentId: (json['agentId'] ?? '').toString(),
        createdAtUnixMs: _integer(json['createdAtUnixMs']),
      );

  final String id;
  final ConversationPrincipalKind kind;
  final String displayName;
  final String agentId;
  final int createdAtUnixMs;
}

final class ClientConversationMembership {
  const ClientConversationMembership({
    required this.id,
    required this.conversationId,
    required this.principal,
    required this.access,
    required this.status,
    required this.joinedAtUnixMs,
    required this.leftAtUnixMs,
  });

  factory ClientConversationMembership.fromJson(Map<String, dynamic> json) =>
      ClientConversationMembership(
        id: (json['id'] ?? '').toString(),
        conversationId: (json['conversationId'] ?? '').toString(),
        principal: ClientConversationPrincipal.fromJson(
          _map(json['principal']),
        ),
        access: ConversationMembershipAccess.fromWire(json['access']),
        status: ConversationMembershipStatus.fromWire(json['status']),
        joinedAtUnixMs: _integer(json['joinedAtUnixMs']),
        leftAtUnixMs: json['leftAtUnixMs'] == null
            ? null
            : _integer(json['leftAtUnixMs']),
      );

  final String id;
  final String conversationId;
  final ClientConversationPrincipal principal;
  final ConversationMembershipAccess access;
  final ConversationMembershipStatus status;
  final int joinedAtUnixMs;
  final int? leftAtUnixMs;
}

final class ClientConversationEventPart {
  const ClientConversationEventPart({
    required this.id,
    required this.eventId,
    required this.ordinal,
    required this.kind,
    required this.content,
    required this.createdAtUnixMs,
  });

  factory ClientConversationEventPart.fromJson(Map<String, dynamic> json) =>
      ClientConversationEventPart(
        id: (json['id'] ?? '').toString(),
        eventId: (json['eventId'] ?? '').toString(),
        ordinal: _integer(json['ordinal']),
        kind: ConversationEventPartKind.fromWire(json['kind']),
        content: (json['content'] ?? '').toString(),
        createdAtUnixMs: _integer(json['createdAtUnixMs']),
      );

  final String id;
  final String eventId;
  final int ordinal;
  final ConversationEventPartKind kind;
  final String content;
  final int createdAtUnixMs;
}

final class ClientConversationEvent {
  const ClientConversationEvent({
    required this.id,
    required this.conversationId,
    required this.sequence,
    required this.authorMembershipId,
    required this.kind,
    required this.createdAtUnixMs,
    required this.finalized,
    required this.parts,
  });

  factory ClientConversationEvent.fromJson(Map<String, dynamic> json) =>
      ClientConversationEvent(
        id: (json['id'] ?? '').toString(),
        conversationId: (json['conversationId'] ?? '').toString(),
        sequence: _integer(json['sequence']),
        authorMembershipId: (json['authorMembershipId'] ?? '').toString(),
        kind: ConversationEventKind.fromWire(json['kind']),
        createdAtUnixMs: _integer(json['createdAtUnixMs']),
        finalized: json['finalized'] == true,
        parts: _maps(
          json['parts'],
        ).map(ClientConversationEventPart.fromJson).toList(growable: false),
      );

  final String id;
  final String conversationId;
  final int sequence;
  final String authorMembershipId;
  final ConversationEventKind kind;
  final int createdAtUnixMs;
  final bool finalized;
  final List<ClientConversationEventPart> parts;
}

final class ClientConversationEventPage {
  const ClientConversationEventPage({
    required this.events,
    required this.nextCursor,
    required this.totalCount,
  });

  factory ClientConversationEventPage.fromJson(Map<String, dynamic> json) =>
      ClientConversationEventPage(
        events: _maps(
          json['events'],
        ).map(ClientConversationEvent.fromJson).toList(growable: false),
        nextCursor: (json['nextCursor'] ?? '').toString(),
        totalCount: _integer(json['totalCount']),
      );

  final List<ClientConversationEvent> events;
  final String nextCursor;
  final int totalCount;
}

final class ClientConversationGroupMemberDraft {
  const ClientConversationGroupMemberDraft({
    required this.agentId,
    required this.displayName,
  });

  final String agentId;
  final String displayName;
}

int _integer(Object? value) => switch (value) {
  final int integer => integer,
  final num number => number.toInt(),
  _ => int.tryParse(value?.toString() ?? '') ?? 0,
};

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : const <Map<String, dynamic>>[];
