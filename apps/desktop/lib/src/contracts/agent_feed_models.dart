import 'package:flutter/foundation.dart';

/// Author of a feed post, comment, or repost. Can represent a local agent,
/// a remote provider account, or another user.
@immutable
class AgentFeedAuthor {
  const AgentFeedAuthor({
    required this.id,
    required this.displayName,
    this.avatarAsset,
    this.isAgent = false,
    this.targetId,
    this.accountId,
  });

  final String id;
  final String displayName;
  final String? avatarAsset;
  final bool isAgent;

  /// Local target id when this author maps to a scanned agent.
  final String? targetId;

  /// Remote account id when this author maps to a mobile provider account.
  final String? accountId;

  AgentFeedAuthor copyWith({
    String? id,
    String? displayName,
    String? avatarAsset,
    bool? isAgent,
    String? targetId,
    String? accountId,
  }) {
    return AgentFeedAuthor(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatarAsset: avatarAsset ?? this.avatarAsset,
      isAgent: isAgent ?? this.isAgent,
      targetId: targetId ?? this.targetId,
      accountId: accountId ?? this.accountId,
    );
  }

  factory AgentFeedAuthor.fromJson(Map<String, dynamic> json) {
    return AgentFeedAuthor(
      id: json['id']?.toString() ?? '',
      displayName: json['displayName']?.toString() ?? '',
      avatarAsset: json['avatarAsset']?.toString(),
      isAgent: json['isAgent'] == true,
      targetId: json['targetId']?.toString(),
      accountId: json['accountId']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'displayName': displayName,
      if (avatarAsset != null) 'avatarAsset': avatarAsset,
      'isAgent': isAgent,
      if (targetId != null) 'targetId': targetId,
      if (accountId != null) 'accountId': accountId,
    };
  }
}

enum AgentFeedPostStatus { working, partial, done, error }

enum AgentFeedDispatchStatus { pending, running, succeeded, failed, retryable }

enum AgentFeedAttachmentTransfer { inlineText, rejected }

/// A bounded attachment snapshot selected explicitly by the user.
///
/// Source paths are intentionally never persisted. Text content is retained
/// only after the controller has enforced the byte and UTF-8 bounds so a
/// retry after restart can reproduce the same dispatch input.
@immutable
class AgentFeedAttachment {
  const AgentFeedAttachment({
    required this.id,
    required this.name,
    required this.mediaType,
    required this.encoding,
    required this.byteLength,
    required this.privacy,
    required this.transfer,
    this.content = '',
    this.errorCode = '',
  });

  final String id;
  final String name;
  final String mediaType;
  final String encoding;
  final int byteLength;
  final String privacy;
  final AgentFeedAttachmentTransfer transfer;
  final String content;
  final String errorCode;

  bool get accepted => transfer == AgentFeedAttachmentTransfer.inlineText;

  factory AgentFeedAttachment.fromJson(Map<String, dynamic> json) {
    return AgentFeedAttachment(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      mediaType: json['mediaType']?.toString() ?? 'application/octet-stream',
      encoding: json['encoding']?.toString() ?? '',
      byteLength: _parseNonNegativeInt(json['byteLength']),
      privacy: json['privacy']?.toString() ?? 'explicit-user-selection',
      transfer: _parseAttachmentTransfer(json['transfer']),
      content: json['content']?.toString() ?? '',
      errorCode: json['errorCode']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'mediaType': mediaType,
      'encoding': encoding,
      'byteLength': byteLength,
      'privacy': privacy,
      'transfer': transfer.name,
      if (content.isNotEmpty) 'content': content,
      if (errorCode.isNotEmpty) 'errorCode': errorCode,
    };
  }
}

/// Durable transactional-outbox row keyed by [dispatchId] and [targetId].
@immutable
class AgentFeedDispatchOutcome {
  const AgentFeedDispatchOutcome({
    required this.dispatchId,
    required this.targetId,
    required this.status,
    required this.attemptCount,
    required this.updatedAt,
    this.errorCode = '',
  });

  final String dispatchId;
  final String targetId;
  final AgentFeedDispatchStatus status;
  final int attemptCount;
  final String updatedAt;
  final String errorCode;

  ({String dispatchId, String targetId}) get key =>
      (dispatchId: dispatchId, targetId: targetId);

  bool get terminal =>
      status == AgentFeedDispatchStatus.succeeded ||
      status == AgentFeedDispatchStatus.failed;

  AgentFeedDispatchOutcome copyWith({
    AgentFeedDispatchStatus? status,
    int? attemptCount,
    String? updatedAt,
    String? errorCode,
  }) {
    return AgentFeedDispatchOutcome(
      dispatchId: dispatchId,
      targetId: targetId,
      status: status ?? this.status,
      attemptCount: attemptCount ?? this.attemptCount,
      updatedAt: updatedAt ?? this.updatedAt,
      errorCode: errorCode ?? this.errorCode,
    );
  }

  factory AgentFeedDispatchOutcome.fromJson(Map<String, dynamic> json) {
    return AgentFeedDispatchOutcome(
      dispatchId: json['dispatchId']?.toString() ?? '',
      targetId: json['targetId']?.toString() ?? '',
      status: _parseDispatchStatus(json['status']),
      attemptCount: _parseNonNegativeInt(json['attemptCount']),
      updatedAt: json['updatedAt']?.toString() ?? '',
      errorCode: json['errorCode']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dispatchId': dispatchId,
      'targetId': targetId,
      'status': status.name,
      'attemptCount': attemptCount,
      'updatedAt': updatedAt,
      if (errorCode.isNotEmpty) 'errorCode': errorCode,
    };
  }
}

/// Metrics captured for a feed post derived from an agent work session.
@immutable
class AgentFeedMetrics {
  const AgentFeedMetrics({
    this.durationMillis = 0,
    this.stepCount = 0,
    this.tokenCount = 0,
    this.issueCount = 0,
  });

  final int durationMillis;
  final int stepCount;
  final int tokenCount;
  final int issueCount;

  AgentFeedMetrics copyWith({
    int? durationMillis,
    int? stepCount,
    int? tokenCount,
    int? issueCount,
  }) {
    return AgentFeedMetrics(
      durationMillis: durationMillis ?? this.durationMillis,
      stepCount: stepCount ?? this.stepCount,
      tokenCount: tokenCount ?? this.tokenCount,
      issueCount: issueCount ?? this.issueCount,
    );
  }

  factory AgentFeedMetrics.fromJson(Map<String, dynamic> json) {
    return AgentFeedMetrics(
      durationMillis: _parseInt(json['durationMillis']),
      stepCount: _parseInt(json['stepCount']),
      tokenCount: _parseInt(json['tokenCount']),
      issueCount: _parseInt(json['issueCount']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'durationMillis': durationMillis,
      'stepCount': stepCount,
      'tokenCount': tokenCount,
      'issueCount': issueCount,
    };
  }
}

/// A single update published by an agent when it completes (or makes progress
/// on) a unit of work.
@immutable
class AgentFeedPost {
  const AgentFeedPost({
    required this.id,
    required this.author,
    required this.createdAt,
    required this.updatedAt,
    required this.title,
    required this.body,
    this.dispatchText = '',
    required this.sourceAgentId,
    this.sourceAgentIds = const [],
    required this.sourceSessionId,
    this.dispatchId = '',
    this.attachments = const [],
    this.status = AgentFeedPostStatus.working,
    this.metrics = const AgentFeedMetrics(),
    this.commentIds = const [],
    this.repostIds = const [],
    this.reactionCounts = const {},
  });

  final String id;
  final AgentFeedAuthor author;
  final String createdAt;
  final String updatedAt;
  final String title;
  final String body;
  final String dispatchText;
  final String sourceAgentId;
  final List<String> sourceAgentIds;
  final String sourceSessionId;
  final String dispatchId;
  final List<AgentFeedAttachment> attachments;
  final AgentFeedPostStatus status;
  final AgentFeedMetrics metrics;
  final List<String> commentIds;
  final List<String> repostIds;
  final Map<String, int> reactionCounts;

  AgentFeedPost copyWith({
    String? id,
    AgentFeedAuthor? author,
    String? createdAt,
    String? updatedAt,
    String? title,
    String? body,
    String? dispatchText,
    String? sourceAgentId,
    List<String>? sourceAgentIds,
    String? sourceSessionId,
    String? dispatchId,
    List<AgentFeedAttachment>? attachments,
    AgentFeedPostStatus? status,
    AgentFeedMetrics? metrics,
    List<String>? commentIds,
    List<String>? repostIds,
    Map<String, int>? reactionCounts,
  }) {
    return AgentFeedPost(
      id: id ?? this.id,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      title: title ?? this.title,
      body: body ?? this.body,
      dispatchText: dispatchText ?? this.dispatchText,
      sourceAgentId: sourceAgentId ?? this.sourceAgentId,
      sourceAgentIds: sourceAgentIds ?? this.sourceAgentIds,
      sourceSessionId: sourceSessionId ?? this.sourceSessionId,
      dispatchId: dispatchId ?? this.dispatchId,
      attachments: attachments ?? this.attachments,
      status: status ?? this.status,
      metrics: metrics ?? this.metrics,
      commentIds: commentIds ?? this.commentIds,
      repostIds: repostIds ?? this.repostIds,
      reactionCounts: reactionCounts ?? this.reactionCounts,
    );
  }

  factory AgentFeedPost.fromJson(Map<String, dynamic> json) {
    return AgentFeedPost(
      id: json['id']?.toString() ?? '',
      author: AgentFeedAuthor.fromJson(
        Map<String, dynamic>.from(json['author'] as Map? ?? {}),
      ),
      createdAt: json['createdAt']?.toString() ?? '',
      updatedAt: json['updatedAt']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      dispatchText: json['dispatchText']?.toString() ?? '',
      sourceAgentId: json['sourceAgentId']?.toString() ?? '',
      sourceAgentIds: _parseStringList(json['sourceAgentIds']),
      sourceSessionId: json['sourceSessionId']?.toString() ?? '',
      dispatchId: json['dispatchId']?.toString() ?? '',
      attachments: _parseTypedList(
        json['attachments'],
        AgentFeedAttachment.fromJson,
      ),
      status: _parseStatus(json['status']),
      metrics: AgentFeedMetrics.fromJson(
        Map<String, dynamic>.from(json['metrics'] as Map? ?? {}),
      ),
      commentIds: _parseStringList(json['commentIds']),
      repostIds: _parseStringList(json['repostIds']),
      reactionCounts: _parseReactionCounts(json['reactionCounts']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'author': author.toJson(),
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'title': title,
      'body': body,
      if (dispatchText.isNotEmpty) 'dispatchText': dispatchText,
      'sourceAgentId': sourceAgentId,
      'sourceAgentIds': sourceAgentIds,
      'sourceSessionId': sourceSessionId,
      'dispatchId': dispatchId,
      'attachments': attachments.map((item) => item.toJson()).toList(),
      'status': status.name,
      'metrics': metrics.toJson(),
      'commentIds': commentIds,
      'repostIds': repostIds,
      'reactionCounts': reactionCounts,
    };
  }
}

/// A comment left on a feed post. Comments act as feedback that the original
/// agent can continue acting on.
@immutable
class AgentFeedComment {
  const AgentFeedComment({
    required this.id,
    required this.postId,
    required this.author,
    required this.createdAt,
    required this.text,
    this.replyToCommentId,
  });

  final String id;
  final String postId;
  final AgentFeedAuthor author;
  final String createdAt;
  final String text;
  final String? replyToCommentId;

  AgentFeedComment copyWith({
    String? id,
    String? postId,
    AgentFeedAuthor? author,
    String? createdAt,
    String? text,
    String? replyToCommentId,
  }) {
    return AgentFeedComment(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      author: author ?? this.author,
      createdAt: createdAt ?? this.createdAt,
      text: text ?? this.text,
      replyToCommentId: replyToCommentId ?? this.replyToCommentId,
    );
  }

  factory AgentFeedComment.fromJson(Map<String, dynamic> json) {
    return AgentFeedComment(
      id: json['id']?.toString() ?? '',
      postId: json['postId']?.toString() ?? '',
      author: AgentFeedAuthor.fromJson(
        Map<String, dynamic>.from(json['author'] as Map? ?? {}),
      ),
      createdAt: json['createdAt']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      replyToCommentId: json['replyToCommentId']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'postId': postId,
      'author': author.toJson(),
      'createdAt': createdAt,
      'text': text,
      if (replyToCommentId != null) 'replyToCommentId': replyToCommentId,
    };
  }
}

/// A repost/handoff record indicating that one agent's work was forwarded to
/// another agent.
@immutable
class AgentFeedRepost {
  const AgentFeedRepost({
    required this.id,
    required this.postId,
    required this.fromAuthor,
    required this.toAgentId,
    required this.toAgentName,
    required this.createdAt,
    this.note = '',
  });

  final String id;
  final String postId;
  final AgentFeedAuthor fromAuthor;
  final String toAgentId;
  final String toAgentName;
  final String createdAt;
  final String note;

  AgentFeedRepost copyWith({
    String? id,
    String? postId,
    AgentFeedAuthor? fromAuthor,
    String? toAgentId,
    String? toAgentName,
    String? createdAt,
    String? note,
  }) {
    return AgentFeedRepost(
      id: id ?? this.id,
      postId: postId ?? this.postId,
      fromAuthor: fromAuthor ?? this.fromAuthor,
      toAgentId: toAgentId ?? this.toAgentId,
      toAgentName: toAgentName ?? this.toAgentName,
      createdAt: createdAt ?? this.createdAt,
      note: note ?? this.note,
    );
  }

  factory AgentFeedRepost.fromJson(Map<String, dynamic> json) {
    return AgentFeedRepost(
      id: json['id']?.toString() ?? '',
      postId: json['postId']?.toString() ?? '',
      fromAuthor: AgentFeedAuthor.fromJson(
        Map<String, dynamic>.from(json['fromAuthor'] as Map? ?? {}),
      ),
      toAgentId: json['toAgentId']?.toString() ?? '',
      toAgentName: json['toAgentName']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      note: json['note']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'postId': postId,
      'fromAuthor': fromAuthor.toJson(),
      'toAgentId': toAgentId,
      'toAgentName': toAgentName,
      'createdAt': createdAt,
      'note': note,
    };
  }
}

/// A followed author entry for the user's following list.
@immutable
class AgentFeedFollowing {
  const AgentFeedFollowing({
    required this.id,
    required this.author,
    required this.followedAt,
  });

  final String id;
  final AgentFeedAuthor author;
  final String followedAt;

  AgentFeedFollowing copyWith({
    String? id,
    AgentFeedAuthor? author,
    String? followedAt,
  }) {
    return AgentFeedFollowing(
      id: id ?? this.id,
      author: author ?? this.author,
      followedAt: followedAt ?? this.followedAt,
    );
  }

  factory AgentFeedFollowing.fromJson(Map<String, dynamic> json) {
    return AgentFeedFollowing(
      id: json['id']?.toString() ?? '',
      author: AgentFeedAuthor.fromJson(
        Map<String, dynamic>.from(json['author'] as Map? ?? {}),
      ),
      followedAt: json['followedAt']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'author': author.toJson(), 'followedAt': followedAt};
  }
}

int _parseInt(dynamic value) {
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

int _parseNonNegativeInt(dynamic value) {
  final parsed = _parseInt(value);
  return parsed < 0 ? 0 : parsed;
}

List<T> _parseTypedList<T>(
  dynamic value,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((item) => fromJson(Map<String, dynamic>.from(item)))
      .toList(growable: false);
}

List<String> _parseStringList(dynamic value) {
  if (value is! List) return const [];
  return value.map((item) => item.toString()).toList(growable: false);
}

Map<String, int> _parseReactionCounts(dynamic value) {
  if (value is! Map) return const {};
  return Map<String, int>.fromEntries(
    value.entries
        .where((e) => e.value is num)
        .map((e) => MapEntry(e.key.toString(), (e.value as num).toInt())),
  );
}

AgentFeedPostStatus _parseStatus(dynamic value) {
  return AgentFeedPostStatus.values.firstWhere(
    (s) => s.name == value?.toString(),
    orElse: () => AgentFeedPostStatus.working,
  );
}

AgentFeedDispatchStatus _parseDispatchStatus(dynamic value) {
  return AgentFeedDispatchStatus.values.firstWhere(
    (status) => status.name == value?.toString(),
    orElse: () => AgentFeedDispatchStatus.failed,
  );
}

AgentFeedAttachmentTransfer _parseAttachmentTransfer(dynamic value) {
  return AgentFeedAttachmentTransfer.values.firstWhere(
    (transfer) => transfer.name == value?.toString(),
    orElse: () => AgentFeedAttachmentTransfer.rejected,
  );
}
