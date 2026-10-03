/// Client projection of the native manual-stop and force-stop control plane.
///
/// The native owner is `licoup_native::platform::stop_control` behind the
/// `agent.conversation.stop`, `agent.conversation.force.preview` and
/// `agent.conversation.force.confirm` methods. Those answers already carry only
/// bounded facts: an owner kind, an opaque correlation id, a bounded
/// disposition, and — for force stop — the durable scope, the affected tasks
/// and stable risk codes. Raw owner errors, command lines and payloads never
/// cross that seam, and this projection never invents them.
///
/// Nothing here decides that work stopped. A stop only *requests*; a
/// confirmed stop is the observation that the exact work is no longer in
/// flight, and an unobserved termination stays [WorkStopStage.unconfirmed].
library;

/// One current work owner that can be stopped manually.
enum WorkStopOwnerKind {
  conversationTurn('conversationTurn'),
  workflowRun('workflowRun'),
  subagentClaim('subagentClaim'),
  laneSession('laneSession'),
  unknown('');

  const WorkStopOwnerKind(this.wireName);
  final String wireName;

  static WorkStopOwnerKind parse(Object? value) {
    final name = value?.toString().trim() ?? '';
    for (final candidate in WorkStopOwnerKind.values) {
      if (candidate != WorkStopOwnerKind.unknown &&
          candidate.wireName == name) {
        return candidate;
      }
    }
    return WorkStopOwnerKind.unknown;
  }
}

/// What one owner reported about a stop request.
enum WorkStopDisposition {
  /// The owner accepted the cancellation for the exact in-flight work.
  acknowledged('acknowledged'),

  /// The owner accepted the request; the effect position stays unknown until it
  /// settles.
  requested('requested'),

  /// The owner reports no in-flight work for the exact identity.
  notActive('not-active'),

  /// No owner path is reachable; nothing was cancelled.
  unavailable('unavailable'),

  /// The request itself was refused.
  invalid('invalid'),

  unknown('');

  const WorkStopDisposition(this.wireName);
  final String wireName;

  static WorkStopDisposition parse(Object? value) {
    final name = value?.toString().trim() ?? '';
    for (final candidate in WorkStopDisposition.values) {
      if (candidate != WorkStopDisposition.unknown &&
          candidate.wireName == name) {
        return candidate;
      }
    }
    return WorkStopDisposition.unknown;
  }
}

/// The visible stop state of one piece of admitted work.
///
/// [stopping] and [unconfirmed] are deliberately distinct: a request that was
/// accepted but not yet observed is still running, and a request the host could
/// not reach never becomes a fabricated completion.
enum WorkStopStage {
  /// No stop has been requested for this work in this session.
  idle,

  /// A stop request was accepted and the work is still observed in flight.
  stopping,

  /// The work is no longer observed in flight after an accepted stop request.
  stopped,

  /// The request could not be tied to a settled outcome. The host answer is
  /// preserved in [WorkStopResult.failureCode] and never presented as success.
  unconfirmed,
}

/// The exact work one stop request names.
///
/// Exactly one durable identity is set, matching the native resolver: a
/// `turnHandle` (Conversation turn), a `runId` (Adaptive Flywheel run), a
/// `claimId` (Subagent claim) or a `sessionId` (supervised lane session).
final class WorkStopRequest {
  const WorkStopRequest({
    this.turnHandle = '',
    this.runId = '',
    this.claimId = '',
    this.sessionId = '',
    this.conversationId = '',
    this.membershipId = '',
    this.callerMembershipId = '',
    this.reason = '',
  });

  final String turnHandle;
  final String runId;
  final String claimId;
  final String sessionId;
  final String conversationId;
  final String membershipId;
  final String callerMembershipId;
  final String reason;

  /// The number of durable identities this request names. The native resolver
  /// refuses an ambiguous request rather than guessing.
  int get identityCount => [
    turnHandle,
    runId,
    claimId,
    sessionId,
  ].where((value) => value.trim().isNotEmpty).length;

  bool get isResolvable => identityCount == 1;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (turnHandle.trim().isNotEmpty) 'turnHandle': turnHandle.trim(),
    if (runId.trim().isNotEmpty) 'runId': runId.trim(),
    if (claimId.trim().isNotEmpty) 'claimId': claimId.trim(),
    if (sessionId.trim().isNotEmpty) 'sessionId': sessionId.trim(),
    if (conversationId.trim().isNotEmpty)
      'conversationId': conversationId.trim(),
    if (membershipId.trim().isNotEmpty) 'membershipId': membershipId.trim(),
    if (callerMembershipId.trim().isNotEmpty)
      'callerMembershipId': callerMembershipId.trim(),
    if (reason.trim().isNotEmpty) 'reason': reason.trim(),
  };
}

/// One `agent.conversation.stop` answer.
final class WorkStopResult {
  const WorkStopResult({
    required this.ok,
    required this.status,
    this.ownerKind = WorkStopOwnerKind.unknown,
    this.disposition = WorkStopDisposition.unknown,
    this.correlationId = '',
    this.failureCode = '',
  });

  /// Fail-closed answer for a control plane this client cannot reach.
  const WorkStopResult.unavailable([this.failureCode = 'work_stop_unavailable'])
    : ok = false,
      status = 'unavailable',
      ownerKind = WorkStopOwnerKind.unknown,
      disposition = WorkStopDisposition.unavailable,
      correlationId = '';

  final bool ok;
  final String status;
  final WorkStopOwnerKind ownerKind;
  final WorkStopDisposition disposition;

  /// The opaque native correlation id for this request.
  final String correlationId;

  /// A stable local or native failure code. Never a raw owner error.
  final String failureCode;

  /// Whether the host accepted the request for the exact work.
  bool get requested =>
      disposition == WorkStopDisposition.acknowledged ||
      disposition == WorkStopDisposition.requested;

  /// A short local reference for later analysis. It carries the opaque
  /// correlation id only — no payload, path or content value.
  String get diagnosticReference =>
      correlationId.isEmpty ? '' : 'stop:$correlationId';

  /// Reads one `agent.conversation.stop` answer.
  factory WorkStopResult.fromJson(Map<String, dynamic> json) {
    final disposition = WorkStopDisposition.parse(json['disposition']);
    final failure =
        (json['error'] is Map ? (json['error'] as Map)['code'] : null)
            ?.toString()
            .trim() ??
        '';
    return WorkStopResult(
      ok: json['ok'] == true,
      status: (json['status'] ?? '').toString().trim(),
      ownerKind: WorkStopOwnerKind.parse(json['ownerKind']),
      disposition: disposition,
      correlationId: (json['correlationId'] ?? '').toString().trim(),
      failureCode: failure.isNotEmpty
          ? failure
          : disposition == WorkStopDisposition.unavailable
          ? 'work_stop_owner_unavailable'
          : disposition == WorkStopDisposition.invalid
          ? 'work_stop_invalid_target'
          : '',
    );
  }
}

/// Projects the visible stop stage from the last host answer and from whether
/// the exact work is still observed in flight.
///
/// [observedActive] comes from the owning projection (the Conversation turn
/// state, the run projection), never from the stop answer alone: only an
/// observation can turn a request into [WorkStopStage.stopped].
WorkStopStage projectWorkStopStage({
  required WorkStopResult? result,
  required bool observedActive,
}) {
  if (result == null) return WorkStopStage.idle;
  if (result.requested) {
    return observedActive ? WorkStopStage.stopping : WorkStopStage.stopped;
  }
  if (result.disposition == WorkStopDisposition.notActive) {
    // "Nothing to stop" is only a completion when the owning projection also
    // stopped observing the work.
    return observedActive ? WorkStopStage.unconfirmed : WorkStopStage.stopped;
  }
  return WorkStopStage.unconfirmed;
}

/// One durable process scope a force stop could terminate.
final class ForceStopCandidate {
  const ForceStopCandidate({
    required this.scopeId,
    this.kind = '',
    this.ownerRef = '',
  });

  final String scopeId;
  final String kind;
  final String ownerRef;

  factory ForceStopCandidate.fromJson(Map<String, dynamic> json) {
    return ForceStopCandidate(
      scopeId: (json['scopeId'] ?? '').toString().trim(),
      kind: (json['kind'] ?? '').toString().trim(),
      ownerRef: (json['ownerRef'] ?? '').toString().trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ForceStopCandidate &&
          other.scopeId == scopeId &&
          other.kind == kind &&
          other.ownerRef == ownerRef;

  @override
  int get hashCode => Object.hash(scopeId, kind, ownerRef);
}

/// One task that a force stop would terminate.
final class ForceStopAffectedTask {
  const ForceStopAffectedTask({required this.taskKind, required this.taskRef});

  final String taskKind;
  final String taskRef;

  factory ForceStopAffectedTask.fromJson(Map<String, dynamic> json) {
    return ForceStopAffectedTask(
      taskKind: (json['taskKind'] ?? '').toString().trim(),
      taskRef: (json['taskRef'] ?? '').toString().trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ForceStopAffectedTask &&
          other.taskKind == taskKind &&
          other.taskRef == taskRef;

  @override
  int get hashCode => Object.hash(taskKind, taskRef);
}

/// The status of one force-stop preview read.
enum ForceStopPreviewStatus {
  /// The host owns more than one process scope; a scope must be chosen.
  scopeRequired,
  preview,
  scopeUnavailable,
  unavailable,
}

/// One `agent.conversation.force.preview` answer.
///
/// The native preview sends no signal and terminates nothing.
final class ForceStopPreview {
  const ForceStopPreview({
    required this.status,
    this.correlationId = '',
    this.candidates = const [],
    this.scopeId = '',
    this.ownerKind = '',
    this.ownerRef = '',
    this.processGroupVerified = false,
    this.affectedTaskCount = 0,
    this.affectedTasks = const [],
    this.riskCodes = const [],
    this.riskSummary = '',
    this.confirmationToken = '',
    this.failureCode = '',
  });

  /// Fail-closed preview for a control plane this client cannot reach.
  const ForceStopPreview.unavailable([
    this.failureCode = 'force_stop_preview_unavailable',
  ]) : status = ForceStopPreviewStatus.unavailable,
       correlationId = '',
       candidates = const [],
       scopeId = '',
       ownerKind = '',
       ownerRef = '',
       processGroupVerified = false,
       affectedTaskCount = 0,
       affectedTasks = const [],
       riskCodes = const [],
       riskSummary = '',
       confirmationToken = '';

  final ForceStopPreviewStatus status;
  final String correlationId;
  final List<ForceStopCandidate> candidates;
  final String scopeId;
  final String ownerKind;
  final String ownerRef;
  final bool processGroupVerified;
  final int affectedTaskCount;
  final List<ForceStopAffectedTask> affectedTasks;

  /// Stable risk codes, for example `unsaved-agent-progress`.
  final List<String> riskCodes;

  /// The host's own bounded summary sentence.
  final String riskSummary;

  /// The token the confirm call must present back. It binds the exact scope
  /// revision the dialog showed.
  final String confirmationToken;

  final String failureCode;

  /// Whether this preview can be confirmed as shown.
  bool get confirmable =>
      status == ForceStopPreviewStatus.preview &&
      scopeId.isNotEmpty &&
      confirmationToken.isNotEmpty;

  /// Short local reference for later analysis.
  String get diagnosticReference =>
      correlationId.isEmpty ? '' : 'force:$correlationId';

  factory ForceStopPreview.fromJson(Map<String, dynamic> json) {
    final scope = json['scope'] is Map
        ? Map<String, dynamic>.from(json['scope'] as Map)
        : const <String, dynamic>{};
    final status = switch ((json['status'] ?? '').toString().trim()) {
      'scope-required' => ForceStopPreviewStatus.scopeRequired,
      'preview' => ForceStopPreviewStatus.preview,
      'scope-unavailable' => ForceStopPreviewStatus.scopeUnavailable,
      _ => ForceStopPreviewStatus.unavailable,
    };
    final error = json['error'] is Map
        ? Map<String, dynamic>.from(json['error'] as Map)
        : const <String, dynamic>{};
    return ForceStopPreview(
      status: status,
      correlationId: (json['correlationId'] ?? '').toString().trim(),
      candidates: [
        for (final item in (json['candidates'] as List?) ?? const [])
          if (item is Map)
            ForceStopCandidate.fromJson(Map<String, dynamic>.from(item)),
      ],
      scopeId: (scope['scopeId'] ?? '').toString().trim(),
      ownerKind: (scope['kind'] ?? '').toString().trim(),
      ownerRef: (scope['ownerRef'] ?? '').toString().trim(),
      processGroupVerified: scope['processGroupVerified'] == true,
      affectedTaskCount: (scope['affectedTaskCount'] as num?)?.toInt() ?? 0,
      affectedTasks: [
        for (final item in (json['affectedTasks'] as List?) ?? const [])
          if (item is Map)
            ForceStopAffectedTask.fromJson(Map<String, dynamic>.from(item)),
      ],
      riskCodes: [
        for (final item in (json['riskCodes'] as List?) ?? const [])
          if (item != null && item.toString().trim().isNotEmpty)
            item.toString().trim(),
      ],
      riskSummary: (json['riskSummary'] ?? '').toString().trim(),
      confirmationToken: (json['confirmationToken'] ?? '').toString().trim(),
      failureCode: (error['code'] ?? '').toString().trim(),
    );
  }
}

/// The observed outcome of one explicit force-stop confirmation.
enum ForceStopConfirmationStatus {
  /// The owned process group exited inside the observation bound.
  observedExit,

  /// The request was sent but no exit was observed inside the bound. The
  /// process may still be running and may still be writing.
  unconfirmed,

  /// The user declined. Nothing was signalled.
  declined,

  /// The request was refused before any signal.
  invalid,

  /// The control plane could not be reached.
  unavailable,
}

/// One `agent.conversation.force.confirm` answer.
final class ForceStopConfirmation {
  const ForceStopConfirmation({
    required this.status,
    this.correlationId = '',
    this.scopeId = '',
    this.signalled = false,
    this.observedExit = false,
    this.forced = false,
    this.reasonCode = '',
    this.failureCode = '',
  });

  const ForceStopConfirmation.unavailable([
    this.failureCode = 'force_stop_confirm_unavailable',
  ]) : status = ForceStopConfirmationStatus.unavailable,
       correlationId = '',
       scopeId = '',
       signalled = false,
       observedExit = false,
       forced = false,
       reasonCode = '';

  final ForceStopConfirmationStatus status;
  final String correlationId;
  final String scopeId;
  final bool signalled;
  final bool observedExit;
  final bool forced;
  final String reasonCode;
  final String failureCode;

  /// Whether the process group is confirmed gone.
  bool get stopped =>
      status == ForceStopConfirmationStatus.observedExit && observedExit;

  /// Short local reference for later analysis.
  String get diagnosticReference =>
      correlationId.isEmpty ? '' : 'force:$correlationId';

  factory ForceStopConfirmation.fromJson(Map<String, dynamic> json) {
    final termination = json['termination'] is Map
        ? Map<String, dynamic>.from(json['termination'] as Map)
        : const <String, dynamic>{};
    final error = json['error'] is Map
        ? Map<String, dynamic>.from(json['error'] as Map)
        : const <String, dynamic>{};
    return ForceStopConfirmation(
      status: switch ((json['status'] ?? '').toString().trim()) {
        'observed-exit' => ForceStopConfirmationStatus.observedExit,
        'unconfirmed' => ForceStopConfirmationStatus.unconfirmed,
        'declined' => ForceStopConfirmationStatus.declined,
        'invalid' => ForceStopConfirmationStatus.invalid,
        _ => ForceStopConfirmationStatus.unavailable,
      },
      correlationId: (json['correlationId'] ?? '').toString().trim(),
      scopeId: (json['scopeId'] ?? '').toString().trim(),
      signalled: json['signalled'] == true,
      observedExit: termination['observedExit'] == true,
      forced: termination['forced'] == true,
      reasonCode: (termination['reasonCode'] ?? '').toString().trim(),
      failureCode: (error['code'] ?? '').toString().trim(),
    );
  }
}

/// Localized copy for the stable force-stop risk codes the host reports.
String forceStopRiskLabel(
  String riskCode, {
  required bool chinese,
}) => switch (riskCode) {
  'unsaved-agent-progress' =>
    chinese ? '正在运行的任务会丢失未保存的进度。' : 'Running tasks lose unsaved progress.',
  'owned-service-terminated' =>
    chinese
        ? 'LicoUp 启动的本地 Agent 服务会被终止。'
        : 'The local Agent service LicoUp started is terminated.',
  'service-restart-required' =>
    chinese ? '该服务需要在之后重新启动。' : 'The service must be started again afterwards.',
  _ => chinese ? '强制停止会中断正在运行的任务。' : 'A force stop interrupts running tasks.',
};
