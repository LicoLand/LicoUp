/// Local Secure Mesh remote-approval inbox projection.
///
/// Holds only display-safe fields for the approval inbox. Operation detail,
/// prompts, tool arguments, and absolute paths stay out of status surfaces.
const String secureMeshApprovalRequestProtocol =
    'secure_mesh.approval_request.v1';
const String secureMeshApprovalResponseProtocol =
    'secure_mesh.approval_response.v1';

enum SecureMeshApprovalStatus { pending, resolved, expired, failed }

enum SecureMeshApprovalDecision { allow, deny, none }

final class SecureMeshApprovalRequest {
  const SecureMeshApprovalRequest({
    required this.pendingOperationId,
    required this.requesterAgentId,
    required this.targetClientId,
    required this.riskLevel,
    required this.displaySummary,
    required this.expiresAt,
    required this.responseNonce,
    required this.adapterCallbackTokenRef,
    required this.adapterStyle,
    required this.status,
    this.policyReason = '',
    this.requestedTools = const [],
    this.trustedEndpointCount = 0,
    this.decision = SecureMeshApprovalDecision.none,
    this.errorCode = '',
    this.originEndpointId = '',
    this.respondingEndpointId = '',
  });

  final String pendingOperationId;
  final String requesterAgentId;
  final String targetClientId;
  final String originEndpointId;
  final String riskLevel;
  final String displaySummary;
  final String policyReason;
  final String expiresAt;
  final String responseNonce;
  final String adapterCallbackTokenRef;
  final String adapterStyle;
  final List<String> requestedTools;
  final int trustedEndpointCount;
  final SecureMeshApprovalStatus status;
  final SecureMeshApprovalDecision decision;
  final String respondingEndpointId;
  final String errorCode;

  bool get isPending => status == SecureMeshApprovalStatus.pending;

  Map<String, dynamic> toRequestParams({
    required List<String> trustedEndpointIds,
  }) {
    return {
      'protocolVersion': secureMeshApprovalRequestProtocol,
      'pendingOperationId': pendingOperationId,
      'requesterAgentId': requesterAgentId,
      'targetClientId': targetClientId,
      'originEndpointId': originEndpointId,
      'riskLevel': riskLevel,
      'displaySummary': displaySummary,
      if (policyReason.trim().isNotEmpty) 'policyReason': policyReason,
      'adapterCallbackTokenRef': adapterCallbackTokenRef,
      'adapterStyle': adapterStyle,
      'expiresAt': expiresAt,
      'responseNonce': responseNonce,
      'requestedTools': requestedTools,
      'trustedEndpointIds': trustedEndpointIds,
    };
  }

  SecureMeshApprovalRequest copyWith({
    String? pendingOperationId,
    String? requesterAgentId,
    String? targetClientId,
    String? originEndpointId,
    String? riskLevel,
    String? displaySummary,
    String? policyReason,
    String? expiresAt,
    String? responseNonce,
    String? adapterCallbackTokenRef,
    String? adapterStyle,
    List<String>? requestedTools,
    int? trustedEndpointCount,
    SecureMeshApprovalStatus? status,
    SecureMeshApprovalDecision? decision,
    String? respondingEndpointId,
    String? errorCode,
  }) {
    return SecureMeshApprovalRequest(
      pendingOperationId: pendingOperationId ?? this.pendingOperationId,
      requesterAgentId: requesterAgentId ?? this.requesterAgentId,
      targetClientId: targetClientId ?? this.targetClientId,
      originEndpointId: originEndpointId ?? this.originEndpointId,
      riskLevel: riskLevel ?? this.riskLevel,
      displaySummary: displaySummary ?? this.displaySummary,
      policyReason: policyReason ?? this.policyReason,
      expiresAt: expiresAt ?? this.expiresAt,
      responseNonce: responseNonce ?? this.responseNonce,
      adapterCallbackTokenRef:
          adapterCallbackTokenRef ?? this.adapterCallbackTokenRef,
      adapterStyle: adapterStyle ?? this.adapterStyle,
      requestedTools: requestedTools ?? this.requestedTools,
      trustedEndpointCount: trustedEndpointCount ?? this.trustedEndpointCount,
      status: status ?? this.status,
      decision: decision ?? this.decision,
      respondingEndpointId: respondingEndpointId ?? this.respondingEndpointId,
      errorCode: errorCode ?? this.errorCode,
    );
  }

  static SecureMeshApprovalRequest? fromInboxItem(Map<String, dynamic> item) {
    final pendingOperationId =
        (item['pendingOperationId'] as String?)?.trim() ?? '';
    if (pendingOperationId.isEmpty) {
      return null;
    }
    final statusMap = item['status'];
    final state = statusMap is Map
        ? (statusMap['state'] as String?)?.trim() ?? 'pending'
        : 'pending';
    final decisionRaw = statusMap is Map
        ? (statusMap['decision'] as String?)?.trim() ?? ''
        : '';
    final tools = <String>[];
    final rawTools = item['requestedTools'];
    if (rawTools is List) {
      for (final tool in rawTools) {
        final name = tool?.toString().trim() ?? '';
        if (name.isNotEmpty) {
          tools.add(name);
        }
      }
    }
    return SecureMeshApprovalRequest(
      pendingOperationId: pendingOperationId,
      requesterAgentId: (item['requesterAgentId'] as String?)?.trim() ?? '',
      targetClientId: (item['targetClientId'] as String?)?.trim() ?? '',
      riskLevel: (item['riskLevel'] as String?)?.trim() ?? 'local_effect',
      displaySummary: (item['displaySummary'] as String?)?.trim() ?? '',
      policyReason: (item['policyReason'] as String?)?.trim() ?? '',
      expiresAt: (item['expiresAt'] as String?)?.trim() ?? '',
      responseNonce: '',
      adapterCallbackTokenRef:
          (item['adapterCallbackTokenRef'] as String?)?.trim() ?? '',
      adapterStyle: (item['adapterStyle'] as String?)?.trim() ?? 'callback',
      requestedTools: List<String>.unmodifiable(tools),
      trustedEndpointCount:
          (item['trustedEndpointCount'] as num?)?.toInt() ?? 0,
      status: switch (state) {
        'resolved' => SecureMeshApprovalStatus.resolved,
        'expired' => SecureMeshApprovalStatus.expired,
        'failed' => SecureMeshApprovalStatus.failed,
        _ => SecureMeshApprovalStatus.pending,
      },
      decision: switch (decisionRaw) {
        'allow' => SecureMeshApprovalDecision.allow,
        'deny' => SecureMeshApprovalDecision.deny,
        _ => SecureMeshApprovalDecision.none,
      },
    );
  }
}
