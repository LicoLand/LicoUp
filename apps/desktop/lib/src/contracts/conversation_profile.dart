/// A client-owned Agent Persona ("智能体"): a named, avatar-bearing profile
/// bound to one local Agent with its own model, reasoning effort and
/// advanced preferences.
///
/// The durable record lives in `client-state/conversation-profiles.json`.
/// A profile materializes in two places with the same `profile:<id>`
/// principal identity: its own direct (non-group) canonical Conversation —
/// surfaced as a contact row in the messaging list — and as a member of
/// group conversations, where its persisted Membership Profile intent
/// carries these preferences into dispatch.
final class ConversationProfile {
  const ConversationProfile({
    required this.id,
    required this.name,
    required this.mascotAvatarId,
    required this.agentId,
    this.modelId = '',
    this.reasoningEffort = '',
    this.permissionMode = '',
    this.environment = '',
    this.contextWindowTokens,
    this.instructions = '',
    required this.createdAtUnixMs,
    this.conversationId = '',
  });

  factory ConversationProfile.fromJson(Map<String, dynamic> json) =>
      ConversationProfile(
        id: (json['id'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        mascotAvatarId: (json['mascotAvatarId'] ?? '').toString(),
        agentId: (json['agentId'] ?? '').toString(),
        modelId: (json['modelId'] ?? '').toString(),
        reasoningEffort: (json['reasoningEffort'] ?? '').toString(),
        permissionMode: (json['permissionMode'] ?? '').toString(),
        environment: (json['environment'] ?? '').toString(),
        contextWindowTokens: (json['contextWindowTokens'] as num?)?.toInt(),
        instructions: (json['instructions'] ?? '').toString(),
        createdAtUnixMs: (json['createdAtUnixMs'] as num?)?.toInt() ?? 0,
        conversationId: (json['conversationId'] ?? '').toString(),
      );

  /// Stable identity; the canonical principal id is `profile:<id>`.
  final String id;
  final String name;

  /// One of the twelve bundled mascot avatar ids (`MascotCatalog.avatars`).
  final String mascotAvatarId;

  /// The backing local Agent (`TargetCandidate.target`) that executes this
  /// profile's turns.
  final String agentId;
  final String modelId;
  final String reasoningEffort;
  final String permissionMode;

  /// Working-directory preference, mapped onto `preferredEnvironment`.
  final String environment;

  /// Requested context window in tokens; admitted into dispatch params.
  final int? contextWindowTokens;

  /// Free-form persona instructions delivered with each turn.
  final String instructions;

  final int createdAtUnixMs;

  /// The profile's direct canonical Conversation id once materialized;
  /// empty until the first creation attempt commits.
  final String conversationId;

  /// The canonical principal identity this profile joins conversations as.
  String get principalId => 'profile:$id';

  /// The Membership Profile intent fields this profile applies on join.
  Map<String, dynamic> get intent => {
    'requiredCapabilities': const <String>[],
    'preferredCapabilities': const <String>[],
    'skillReferences': const <String>[],
    'preferredModel': modelId.trim().isEmpty ? null : modelId.trim(),
    'preferredReasoningEffort': reasoningEffort.trim().isEmpty
        ? null
        : reasoningEffort.trim(),
    'preferredEnvironment': environment.trim().isEmpty
        ? null
        : environment.trim(),
    'preferredPermissionMode': permissionMode.trim().isEmpty
        ? null
        : permissionMode.trim(),
    'preferredInstructions': instructions.trim().isEmpty
        ? null
        : instructions.trim(),
    'preferredContextWindow': contextWindowTokens,
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mascotAvatarId': mascotAvatarId,
    'agentId': agentId,
    'modelId': modelId,
    'reasoningEffort': reasoningEffort,
    'permissionMode': permissionMode,
    'environment': environment,
    if (contextWindowTokens != null) 'contextWindowTokens': contextWindowTokens,
    'instructions': instructions,
    'createdAtUnixMs': createdAtUnixMs,
    'conversationId': conversationId,
  };

  ConversationProfile copyWith({String? conversationId}) => ConversationProfile(
    id: id,
    name: name,
    mascotAvatarId: mascotAvatarId,
    agentId: agentId,
    modelId: modelId,
    reasoningEffort: reasoningEffort,
    permissionMode: permissionMode,
    environment: environment,
    contextWindowTokens: contextWindowTokens,
    instructions: instructions,
    createdAtUnixMs: createdAtUnixMs,
    conversationId: conversationId ?? this.conversationId,
  );

  @override
  bool operator ==(Object other) =>
      other is ConversationProfile &&
      other.id == id &&
      other.name == name &&
      other.mascotAvatarId == mascotAvatarId &&
      other.agentId == agentId &&
      other.modelId == modelId &&
      other.reasoningEffort == reasoningEffort &&
      other.permissionMode == permissionMode &&
      other.environment == environment &&
      other.contextWindowTokens == contextWindowTokens &&
      other.instructions == instructions &&
      other.createdAtUnixMs == createdAtUnixMs &&
      other.conversationId == conversationId;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    mascotAvatarId,
    agentId,
    modelId,
    reasoningEffort,
    permissionMode,
    environment,
    contextWindowTokens,
    instructions,
    createdAtUnixMs,
    conversationId,
  );
}
