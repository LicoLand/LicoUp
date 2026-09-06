import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

sealed class ConversationIntent {
  const ConversationIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshConversationCatalog extends ConversationIntent {
  const RefreshConversationCatalog({this.agentId = '', super.trace});

  final String agentId;
}

final class LoadMoreConversationSessions extends ConversationIntent {
  const LoadMoreConversationSessions({super.trace});
}

final class SelectConversationSession extends ConversationIntent {
  const SelectConversationSession(this.sessionId, {super.trace});

  final String sessionId;
}

final class SelectCanonicalConversation extends ConversationIntent {
  const SelectCanonicalConversation(this.conversationId, {super.trace});

  final String conversationId;
}

final class ClearCanonicalConversationSelection extends ConversationIntent {
  const ClearCanonicalConversationSelection({super.trace});
}

final class CreateCanonicalConversationGroup extends ConversationIntent {
  CreateCanonicalConversationGroup({
    required this.title,
    required Iterable<ClientConversationGroupMemberDraft> members,
    super.trace,
  }) : members = List<ClientConversationGroupMemberDraft>.unmodifiable(members);

  final String title;
  final List<ClientConversationGroupMemberDraft> members;
}

final class StartConversationSession extends ConversationIntent {
  const StartConversationSession({super.trace});
}

final class LoadEarlierConversationEvents extends ConversationIntent {
  const LoadEarlierConversationEvents(this.conversationId, {super.trace});

  final String conversationId;
}

final class PostConversationMessage extends ConversationIntent {
  PostConversationMessage({
    required this.conversationId,
    required this.content,
    required Iterable<String> addressedMembershipIds,
    this.dispatchCanonical = true,
    super.trace,
  }) : addressedMembershipIds = List<String>.unmodifiable(
         addressedMembershipIds,
       );

  final String conversationId;
  final String content;
  final List<String> addressedMembershipIds;
  final bool dispatchCanonical;
}

final class UpdateConversationDraft extends ConversationIntent {
  const UpdateConversationDraft(this.conversationId, this.draft, {super.trace});

  final String conversationId;
  final String draft;
}

final class CopyConversationText extends ConversationIntent {
  const CopyConversationText(this.text, {super.trace});

  final String text;
}

final class AddConversationAttachment extends ConversationIntent {
  const AddConversationAttachment(this.conversationId, {super.trace});

  final String conversationId;
}

final class PasteConversationAttachment extends ConversationIntent {
  const PasteConversationAttachment(this.conversationId, {super.trace});

  final String conversationId;
}

final class StageConversationAttachments extends ConversationIntent {
  StageConversationAttachments(
    this.conversationId,
    Iterable<ConversationAttachment> attachments, {
    super.trace,
  }) : attachments = List<ConversationAttachment>.unmodifiable(attachments);

  final String conversationId;
  final List<ConversationAttachment> attachments;
}

final class SetConversationAttachmentStatus extends ConversationIntent {
  const SetConversationAttachmentStatus(
    this.conversationId,
    this.statusCode, {
    super.trace,
  });

  final String conversationId;
  final String statusCode;
}

final class ClearConversationAttachments extends ConversationIntent {
  const ClearConversationAttachments(this.conversationId, {super.trace});

  final String conversationId;
}

final class SelectConversationModel extends ConversationIntent {
  const SelectConversationModel(this.model, {super.trace});

  final String model;
}

final class SelectConversationReasoningEffort extends ConversationIntent {
  const SelectConversationReasoningEffort(this.effort, {super.trace});

  final String effort;
}

final class SelectConversationLicoProfile extends ConversationIntent {
  const SelectConversationLicoProfile(this.profile, {super.trace});

  final String profile;
}

final class RetryConversationPermission extends ConversationIntent {
  const RetryConversationPermission({this.remember = false, super.trace});

  final bool remember;
}

final class DismissConversationPermission extends ConversationIntent {
  const DismissConversationPermission({super.trace});
}

final class AuthorizeConversationRuntime extends ConversationIntent {
  const AuthorizeConversationRuntime({super.trace});
}

final class CopyConversationFailure extends ConversationIntent {
  const CopyConversationFailure(this.content, {super.trace});

  final String content;
}

final class ReplaceConversationAttachments extends ConversationIntent {
  ReplaceConversationAttachments(
    this.conversationId,
    Iterable<ConversationAttachment> attachments, {
    this.statusCode = '',
    super.trace,
  }) : attachments = List<ConversationAttachment>.unmodifiable(attachments);

  final String conversationId;
  final List<ConversationAttachment> attachments;
  final String statusCode;
}

final class RemoveConversationAttachment extends ConversationIntent {
  const RemoveConversationAttachment(
    this.conversationId,
    this.attachmentId, {
    super.trace,
  });

  final String conversationId;
  final String attachmentId;
}

final class RetryConversationDispatch extends ConversationIntent {
  const RetryConversationDispatch(
    this.conversationId,
    this.membershipId, {
    super.trace,
  });

  final String conversationId;
  final String membershipId;
}

final class DismissConversationFailure extends ConversationIntent {
  const DismissConversationFailure(
    this.conversationId,
    this.membershipId, {
    super.trace,
  });

  final String conversationId;
  final String membershipId;
}

final class InterruptConversationTurn extends ConversationIntent {
  const InterruptConversationTurn(
    this.conversationId,
    this.membershipId, {
    super.trace,
  });

  final String conversationId;
  final String membershipId;
}

final class RetryCanonicalConversationMessage extends ConversationIntent {
  const RetryCanonicalConversationMessage(this.eventId, {super.trace});

  final String eventId;
}

final class DeleteCanonicalConversationMessage extends ConversationIntent {
  const DeleteCanonicalConversationMessage(this.eventId, {super.trace});

  final String eventId;
}

final class RefreshCanonicalAssistantThread extends ConversationIntent {
  const RefreshCanonicalAssistantThread({super.trace});
}

final class RefreshCanonicalAssistantProfile extends ConversationIntent {
  const RefreshCanonicalAssistantProfile({super.trace});
}

final class SurfaceConversationFailure extends ConversationIntent {
  const SurfaceConversationFailure({
    required this.stage,
    required this.reasonCode,
    super.trace,
  });

  final String stage;
  final String reasonCode;
}

final class EnsureCanonicalAgentMembership extends ConversationIntent {
  const EnsureCanonicalAgentMembership({
    required this.agentId,
    required this.displayName,
    super.trace,
  });

  final String agentId;
  final String displayName;
}

final class SetCanonicalAssistantMembership extends ConversationIntent {
  const SetCanonicalAssistantMembership(this.membershipId, {super.trace});

  final String? membershipId;
}

final class SetCanonicalStrategyRevision extends ConversationIntent {
  const SetCanonicalStrategyRevision(this.revision, {super.trace});

  final String? revision;
}

final class SetCanonicalConversationPinned extends ConversationIntent {
  const SetCanonicalConversationPinned(
    this.conversationId,
    this.pinned, {
    super.trace,
  });

  final String conversationId;
  final bool pinned;
}

final class SetCanonicalConversationSurfaceAttached extends ConversationIntent {
  const SetCanonicalConversationSurfaceAttached(this.attached, {super.trace});

  final bool attached;
}

final class SetConversationTabActive extends ConversationIntent {
  const SetConversationTabActive(
    this.conversationId,
    this.active, {
    super.trace,
  });

  final String conversationId;
  final bool active;
}

final class ArchiveConversation extends ConversationIntent {
  const ArchiveConversation(this.conversationId, {super.trace});

  final String conversationId;
}

final class RestoreConversation extends ConversationIntent {
  const RestoreConversation(this.conversationId, {super.trace});

  final String conversationId;
}

final class BackupAllNativeConversations extends ConversationIntent {
  const BackupAllNativeConversations({
    required this.sourceAgentId,
    required this.destination,
    super.trace,
  });

  final String sourceAgentId;
  final String destination;
}

final class BackupNativeConversationsByExactKeyword extends ConversationIntent {
  const BackupNativeConversationsByExactKeyword({
    required this.query,
    required this.sourceAgentId,
    required this.destination,
    super.trace,
  });

  final String query;
  final String sourceAgentId;
  final String destination;
}
