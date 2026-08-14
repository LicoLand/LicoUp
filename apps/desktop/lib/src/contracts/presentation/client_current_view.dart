import 'semantic_destination.dart';

enum ClientConversationViewKind { welcome, group, agent }

/// The single persisted description of what the user is currently viewing.
///
/// The top-level [section] and the Agents workspace selection travel together:
/// opening Settings does not forget the conversation that should be visible
/// when the user returns to Agents.
final class ClientCurrentView {
  factory ClientCurrentView({
    required ClientSection section,
    required ClientConversationViewKind conversationKind,
    String groupConversationId = '',
    String agentId = '',
    String sessionId = '',
  }) {
    final group = groupConversationId.trim();
    final agent = agentId.trim();
    final session = sessionId.trim();
    switch (conversationKind) {
      case ClientConversationViewKind.welcome:
        if (group.isNotEmpty || agent.isNotEmpty || session.isNotEmpty) {
          throw const FormatException('current_view_welcome_identity_invalid');
        }
        break;
      case ClientConversationViewKind.group:
        if (group.isEmpty || agent.isNotEmpty || session.isNotEmpty) {
          throw const FormatException('current_view_group_identity_invalid');
        }
        break;
      case ClientConversationViewKind.agent:
        if (group.isNotEmpty || agent.isEmpty) {
          throw const FormatException('current_view_agent_identity_invalid');
        }
        break;
    }
    return ClientCurrentView._(
      section: section,
      conversationKind: conversationKind,
      groupConversationId: group,
      agentId: agent,
      sessionId: session,
    );
  }

  const ClientCurrentView._({
    required this.section,
    required this.conversationKind,
    required this.groupConversationId,
    required this.agentId,
    required this.sessionId,
  });

  factory ClientCurrentView.welcome({
    ClientSection section = ClientSection.agents,
  }) => ClientCurrentView(
    section: section,
    conversationKind: ClientConversationViewKind.welcome,
  );

  factory ClientCurrentView.group({
    required String conversationId,
    ClientSection section = ClientSection.agents,
  }) => ClientCurrentView(
    section: section,
    conversationKind: ClientConversationViewKind.group,
    groupConversationId: conversationId,
  );

  factory ClientCurrentView.agent({
    required String agentId,
    String sessionId = '',
    ClientSection section = ClientSection.agents,
  }) => ClientCurrentView(
    section: section,
    conversationKind: ClientConversationViewKind.agent,
    agentId: agentId,
    sessionId: sessionId,
  );

  final ClientSection section;
  final ClientConversationViewKind conversationKind;
  final String groupConversationId;
  final String agentId;
  final String sessionId;

  ClientCurrentView withSection(ClientSection value) => ClientCurrentView(
    section: value,
    conversationKind: conversationKind,
    groupConversationId: groupConversationId,
    agentId: agentId,
    sessionId: sessionId,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientCurrentView &&
          other.section == section &&
          other.conversationKind == conversationKind &&
          other.groupConversationId == groupConversationId &&
          other.agentId == agentId &&
          other.sessionId == sessionId;

  @override
  int get hashCode => Object.hash(
    section,
    conversationKind,
    groupConversationId,
    agentId,
    sessionId,
  );
}

abstract interface class ClientCurrentViewStore {
  Future<ClientCurrentView?> load(Object portableData);

  Future<void> save(Object portableData, ClientCurrentView view);
}
