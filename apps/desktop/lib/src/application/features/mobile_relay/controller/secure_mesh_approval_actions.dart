part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientSecureMeshApprovalActions on ClientController {
  Future<void> ingestSecureMeshApprovalRequest({
    required String pendingOperationId,
    required String requesterAgentId,
    required String targetClientId,
    required String originEndpointId,
    required String displaySummary,
    required String adapterCallbackTokenRef,
    required String responseNonce,
    required String expiresAt,
    required List<String> trustedEndpointIds,
    String riskLevel = 'local_effect',
    String policyReason = '',
    String adapterStyle = 'callback',
    List<String> requestedTools = const [],
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    final normalizedId = pendingOperationId.trim();
    final normalizedSummary = displaySummary.trim();
    if (normalizedId.isEmpty ||
        normalizedSummary.isEmpty ||
        trustedEndpointIds.isEmpty) {
      lastError = 'secure_mesh_approval_request_invalid';
      _setLocalizedStatusMessage(
        '远程审批请求无效。',
        'The remote-approval request is invalid.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在登记远程审批请求。',
      'Registering the remote-approval request.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      final request = SecureMeshApprovalRequest(
        pendingOperationId: normalizedId,
        requesterAgentId: requesterAgentId.trim(),
        targetClientId: targetClientId.trim(),
        originEndpointId: originEndpointId.trim(),
        riskLevel: riskLevel.trim().isEmpty ? 'local_effect' : riskLevel.trim(),
        displaySummary: normalizedSummary,
        policyReason: policyReason.trim(),
        expiresAt: expiresAt.trim(),
        responseNonce: responseNonce.trim(),
        adapterCallbackTokenRef: adapterCallbackTokenRef.trim(),
        adapterStyle: adapterStyle.trim().isEmpty
            ? 'callback'
            : adapterStyle.trim(),
        requestedTools: List<String>.unmodifiable(requestedTools),
        trustedEndpointCount: trustedEndpointIds.length,
        status: SecureMeshApprovalStatus.pending,
      );
      final capability = await mobileRelayService
          .evaluateSecureMeshApprovalAdapterCapability(
            agentService: agentService,
            agentId: request.requesterAgentId,
          );
      secureMeshApprovalAdapterCapability = capability;
      if (capability['approvalsSupported'] != true ||
          capability['remoteApprovalBridge'] != true) {
        throw StateError('secure_mesh_approval_adapter_unsupported');
      }
      final registered = await mobileRelayService
          .evaluateSecureMeshApprovalRequest(
            agentService: agentService,
            request: request.toRequestParams(
              trustedEndpointIds: trustedEndpointIds,
            ),
          );
      secureMeshApprovalLastAction = registered;
      if (registered['ok'] != true) {
        throw StateError('secure_mesh_approval_request_failed');
      }
      final fanout = await mobileRelayService.evaluateSecureMeshApprovalFanout(
        agentService: agentService,
        pendingOperationId: normalizedId,
      );
      if (fanout['ok'] != true || fanout['plaintextRelayBlocked'] != true) {
        throw StateError('secure_mesh_approval_fanout_failed');
      }
      secureMeshApprovalInbox = _upsertSecureMeshApproval(
        request.copyWith(
          trustedEndpointCount:
              (fanout['trustedEndpointCount'] as num?)?.toInt() ??
              trustedEndpointIds.length,
        ),
      );
      _setLocalizedStatusMessage(
        '远程审批已进入收件箱：${request.requesterAgentId}',
        'Remote approval queued in the inbox: ${request.requesterAgentId}',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to ingest secure mesh approval: $error');
      lastError = 'secure_mesh_approval_request_failed';
      _setLocalizedStatusMessage(
        '远程审批登记失败。',
        'Remote-approval registration failed.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> refreshSecureMeshApprovalInbox({
    bool includeResolved = true,
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _notifyStateChanged();
    try {
      final inbox = await mobileRelayService.listSecureMeshApprovalInbox(
        agentService: agentService,
        includeResolved: includeResolved,
      );
      secureMeshApprovalLastAction = inbox;
      if (inbox['ok'] != true || inbox['plaintextRelayBlocked'] != true) {
        throw StateError('secure_mesh_approval_inbox_failed');
      }
      final items = inbox['items'];
      final priorNonces = <String, String>{
        for (final item in secureMeshApprovalInbox)
          if (item.responseNonce.trim().isNotEmpty)
            item.pendingOperationId: item.responseNonce,
        for (final item in secureMeshApprovalInbox)
          if (item.originEndpointId.trim().isNotEmpty)
            '${item.pendingOperationId}::origin': item.originEndpointId,
      };
      final next = <SecureMeshApprovalRequest>[];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) {
            continue;
          }
          final mapped = SecureMeshApprovalRequest.fromInboxItem(
            Map<String, dynamic>.from(item),
          );
          if (mapped == null) {
            continue;
          }
          next.add(
            mapped.copyWith(
              responseNonce:
                  priorNonces[mapped.pendingOperationId] ??
                  mapped.responseNonce,
              originEndpointId:
                  priorNonces['${mapped.pendingOperationId}::origin'] ??
                  mapped.originEndpointId,
            ),
          );
        }
      }
      secureMeshApprovalInbox = List<SecureMeshApprovalRequest>.unmodifiable(
        next,
      );
      _setLocalizedStatusMessage(
        '远程审批收件箱已刷新。',
        'Remote-approval inbox refreshed.',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to refresh secure mesh approval inbox: $error');
      lastError = 'secure_mesh_approval_inbox_failed';
      _setLocalizedStatusMessage(
        '远程审批收件箱刷新失败。',
        'Remote-approval inbox refresh failed.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> resolveSecureMeshApproval({
    required String pendingOperationId,
    required bool allow,
    required String respondingEndpointId,
    required String responseNonce,
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    final normalizedId = pendingOperationId.trim();
    final normalizedEndpoint = respondingEndpointId.trim();
    final normalizedNonce = responseNonce.trim();
    if (normalizedId.isEmpty ||
        normalizedEndpoint.isEmpty ||
        normalizedNonce.isEmpty) {
      lastError = 'secure_mesh_approval_response_invalid';
      _setLocalizedStatusMessage(
        '远程审批响应无效。',
        'The remote-approval response is invalid.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      allow ? '正在批准远程请求。' : '正在拒绝远程请求。',
      allow ? 'Approving the remote request.' : 'Denying the remote request.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      final resolved = await mobileRelayService.resolveSecureMeshApproval(
        agentService: agentService,
        pendingOperationId: normalizedId,
        decision: allow ? 'allow' : 'deny',
        respondingEndpointId: normalizedEndpoint,
        responseNonce: normalizedNonce,
      );
      secureMeshApprovalLastAction = resolved;
      if (resolved['ok'] != true &&
          resolved['code'] != 'secure_mesh_approval_already_resolved') {
        throw StateError(
          resolved['code']?.toString() ?? 'secure_mesh_approval_resolve_failed',
        );
      }
      final decision = allow
          ? SecureMeshApprovalDecision.allow
          : SecureMeshApprovalDecision.deny;
      SecureMeshApprovalRequest? existing;
      for (final item in secureMeshApprovalInbox) {
        if (item.pendingOperationId == normalizedId) {
          existing = item;
          break;
        }
      }
      final next =
          (existing ??
                  SecureMeshApprovalRequest(
                    pendingOperationId: normalizedId,
                    requesterAgentId: '',
                    targetClientId: '',
                    riskLevel: 'local_effect',
                    displaySummary: '',
                    expiresAt: '',
                    responseNonce: normalizedNonce,
                    adapterCallbackTokenRef: '',
                    adapterStyle: 'callback',
                    status: SecureMeshApprovalStatus.pending,
                  ))
              .copyWith(
                status: SecureMeshApprovalStatus.resolved,
                decision: decision,
                respondingEndpointId: normalizedEndpoint,
                errorCode: resolved['ok'] == true
                    ? ''
                    : (resolved['code']?.toString() ?? ''),
              );
      secureMeshApprovalInbox = _upsertSecureMeshApproval(next);
      if (resolved['ok'] == true) {
        _setLocalizedStatusMessage(
          allow ? '远程审批已批准。' : '远程审批已拒绝。',
          allow ? 'Remote approval granted.' : 'Remote approval denied.',
        );
      } else {
        _setLocalizedStatusMessage(
          '远程审批已由其他客户端处理。',
          'Remote approval was already resolved on another client.',
        );
      }
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to resolve secure mesh approval: $error');
      lastError = 'secure_mesh_approval_resolve_failed';
      _setLocalizedStatusMessage(
        '远程审批处理失败。',
        'Remote-approval resolution failed.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  List<SecureMeshApprovalRequest> _upsertSecureMeshApproval(
    SecureMeshApprovalRequest request,
  ) {
    final next = <SecureMeshApprovalRequest>[
      for (final item in secureMeshApprovalInbox)
        if (item.pendingOperationId != request.pendingOperationId) item,
      request,
    ];
    if (next.length <= 24) {
      return List<SecureMeshApprovalRequest>.unmodifiable(next);
    }
    return List<SecureMeshApprovalRequest>.unmodifiable(
      next.sublist(next.length - 24),
    );
  }
}
