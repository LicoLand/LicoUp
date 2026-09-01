import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller_support.dart';
import 'package:licoup/src/application/features/mobile_relay/policy/secure_mesh_policy.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

/// Owns the redacted approval inbox and short-lived response secrets.
final class SecureMeshApprovalController extends ChangeNotifier {
  SecureMeshApprovalController({
    required SecureMeshGateway gateway,
    required MobileRelayOperationGate operationGate,
    required SecureMeshStatusReporter report,
  }) : _gateway = gateway,
       _operationGate = operationGate,
       _report = report;

  final SecureMeshGateway _gateway;
  final MobileRelayOperationGate _operationGate;
  final SecureMeshStatusReporter _report;

  List<SecureMeshApprovalRequest> _inbox = const [];
  Map<String, dynamic>? _lastAction;
  Map<String, dynamic>? _adapterCapability;
  final Map<String, _SecureMeshApprovalSecrets> _secrets = {};

  List<SecureMeshApprovalRequest> get inbox => _inbox;
  Map<String, dynamic>? get lastAction => _lastAction;
  Map<String, dynamic>? get adapterCapability => _adapterCapability;

  bool canResolve(String pendingOperationId) {
    final retained = _secrets[pendingOperationId.trim()];
    return retained != null &&
        retained.originEndpointId.trim().isNotEmpty &&
        retained.responseNonce.trim().isNotEmpty;
  }

  void replaceInbox(List<SecureMeshApprovalRequest> value) {
    final public = <SecureMeshApprovalRequest>[];
    for (final request in value) {
      _rememberSecrets(request);
      public.add(SecureMeshPolicy.publicApproval(request));
    }
    _inbox = List<SecureMeshApprovalRequest>.unmodifiable(public);
    _pruneSecrets();
    notifyListeners();
  }

  void replaceLastAction(Map<String, dynamic>? value) {
    _lastAction = value == null
        ? null
        : SecureMeshPolicy.approvalActionProjection(value);
    notifyListeners();
  }

  void replaceAdapterCapability(Map<String, dynamic>? value) {
    _adapterCapability = value == null
        ? null
        : SecureMeshPolicy.approvalCapabilityProjection(value);
    notifyListeners();
  }

  Future<void> ingest({
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
    final id = pendingOperationId.trim();
    final summary = displaySummary.trim();
    if (id.isEmpty || summary.isEmpty || trustedEndpointIds.isEmpty) {
      _report(
        '远程审批请求无效。',
        'The remote-approval request is invalid.',
        errorCode: 'secure_mesh_approval_request_invalid',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _report('正在登记远程审批请求。', 'Registering the remote-approval request.');
    notifyListeners();
    final request = SecureMeshApprovalRequest(
      pendingOperationId: id,
      requesterAgentId: requesterAgentId.trim(),
      targetClientId: targetClientId.trim(),
      originEndpointId: originEndpointId.trim(),
      riskLevel: riskLevel.trim().isEmpty ? 'local_effect' : riskLevel.trim(),
      displaySummary: summary,
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
    _rememberSecrets(request);
    try {
      final rawCapability = await _gateway.evaluateApprovalAdapterCapability(
        request.requesterAgentId,
      );
      _adapterCapability = SecureMeshPolicy.approvalCapabilityProjection(
        rawCapability,
      );
      if (rawCapability['approvalsSupported'] != true ||
          rawCapability['remoteApprovalBridge'] != true) {
        throw const SecureMeshPolicyFailure();
      }
      final rawRegistered = await _gateway.evaluateApprovalRequest(
        request.toRequestParams(trustedEndpointIds: trustedEndpointIds),
      );
      _lastAction = SecureMeshPolicy.approvalActionProjection(rawRegistered);
      if (rawRegistered['ok'] != true) {
        throw const SecureMeshPolicyFailure();
      }
      final rawFanout = await _gateway.evaluateApprovalFanout(id);
      if (rawFanout['ok'] != true ||
          rawFanout['plaintextRelayBlocked'] != true) {
        throw const SecureMeshPolicyFailure();
      }
      final public = SecureMeshPolicy.publicApproval(
        request.copyWith(
          trustedEndpointCount:
              (rawFanout['trustedEndpointCount'] as num?)?.toInt() ??
              trustedEndpointIds.length,
        ),
      );
      _inbox = SecureMeshPolicy.upsertApproval(_inbox, public);
      _pruneSecrets();
      _report(
        '远程审批已进入收件箱：${request.requesterAgentId}',
        'Remote approval queued in the inbox: ${request.requesterAgentId}',
      );
    } catch (_) {
      _report(
        '远程审批登记失败。',
        'Remote-approval registration failed.',
        errorCode: 'secure_mesh_approval_request_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> refreshInbox({bool includeResolved = true}) async {
    if (!_operationGate.tryAcquire()) return;
    notifyListeners();
    try {
      final raw = await _gateway.listApprovalInbox(
        includeResolved: includeResolved,
      );
      _lastAction = SecureMeshPolicy.approvalActionProjection(raw);
      if (raw['ok'] != true || raw['plaintextRelayBlocked'] != true) {
        throw const SecureMeshPolicyFailure();
      }
      final next = <SecureMeshApprovalRequest>[];
      final items = raw['items'];
      if (items is List) {
        for (final item in items) {
          if (item is! Map) continue;
          SecureMeshApprovalRequest? mapped;
          try {
            mapped = SecureMeshApprovalRequest.fromInboxItem(
              Map<String, dynamic>.from(item),
            );
          } on TypeError {
            mapped = null;
          }
          if (mapped == null) continue;
          _rememberSecrets(mapped);
          next.add(SecureMeshPolicy.publicApproval(mapped));
        }
      }
      _inbox = List<SecureMeshApprovalRequest>.unmodifiable(
        next.take(SecureMeshPolicy.maximumApprovals),
      );
      _pruneSecrets();
      _report('远程审批收件箱已刷新。', 'Remote-approval inbox refreshed.');
    } catch (_) {
      _report(
        '远程审批收件箱刷新失败。',
        'Remote-approval inbox refresh failed.',
        errorCode: 'secure_mesh_approval_inbox_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> resolve({
    required String pendingOperationId,
    required bool allow,
    String respondingEndpointId = '',
    String responseNonce = '',
  }) async {
    final id = pendingOperationId.trim();
    final retained = _secrets[id];
    final endpoint = retained?.originEndpointId.trim().isNotEmpty == true
        ? retained!.originEndpointId.trim()
        : respondingEndpointId.trim();
    final nonce = retained?.responseNonce.trim().isNotEmpty == true
        ? retained!.responseNonce.trim()
        : responseNonce.trim();
    if (id.isEmpty || endpoint.isEmpty || nonce.isEmpty) {
      _report(
        '远程审批响应无效。',
        'The remote-approval response is invalid.',
        errorCode: 'secure_mesh_approval_response_invalid',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _report(
      allow ? '正在批准远程请求。' : '正在拒绝远程请求。',
      allow ? 'Approving the remote request.' : 'Denying the remote request.',
    );
    notifyListeners();
    try {
      final raw = await _gateway.resolveApproval(
        pendingOperationId: id,
        decision: allow ? 'allow' : 'deny',
        respondingEndpointId: endpoint,
        responseNonce: nonce,
      );
      _lastAction = SecureMeshPolicy.approvalActionProjection(raw);
      final rawCode = SecureMeshPolicy.stableCode(
        raw['code'],
        fallback: 'secure_mesh_approval_resolve_failed',
      );
      if (raw['ok'] != true &&
          rawCode != 'secure_mesh_approval_already_resolved') {
        throw const SecureMeshPolicyFailure();
      }
      SecureMeshApprovalRequest? existing;
      for (final request in _inbox) {
        if (request.pendingOperationId == id) {
          existing = request;
          break;
        }
      }
      final resolved =
          (existing ??
                  SecureMeshApprovalRequest(
                    pendingOperationId: id,
                    requesterAgentId: '',
                    targetClientId: '',
                    riskLevel: 'local_effect',
                    displaySummary: '',
                    expiresAt: '',
                    responseNonce: '',
                    adapterCallbackTokenRef: '',
                    adapterStyle: 'callback',
                    status: SecureMeshApprovalStatus.pending,
                  ))
              .copyWith(
                status: SecureMeshApprovalStatus.resolved,
                decision: allow
                    ? SecureMeshApprovalDecision.allow
                    : SecureMeshApprovalDecision.deny,
                errorCode: raw['ok'] == true ? '' : rawCode,
              );
      _inbox = SecureMeshPolicy.upsertApproval(
        _inbox,
        SecureMeshPolicy.publicApproval(resolved),
      );
      _secrets.remove(id);
      _report(
        raw['ok'] == true
            ? (allow ? '远程审批已批准。' : '远程审批已拒绝。')
            : '远程审批已由其他客户端处理。',
        raw['ok'] == true
            ? (allow ? 'Remote approval granted.' : 'Remote approval denied.')
            : 'Remote approval was already resolved on another client.',
      );
    } catch (_) {
      _report(
        '远程审批处理失败。',
        'Remote-approval resolution failed.',
        errorCode: 'secure_mesh_approval_resolve_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  void _rememberSecrets(SecureMeshApprovalRequest request) {
    final id = request.pendingOperationId.trim();
    if (id.isEmpty) return;
    final prior = _secrets[id];
    final nonce = request.responseNonce.trim();
    final token = request.adapterCallbackTokenRef.trim();
    final origin = request.originEndpointId.trim();
    if (nonce.isEmpty && token.isEmpty && origin.isEmpty && prior != null) {
      return;
    }
    _secrets[id] = _SecureMeshApprovalSecrets(
      responseNonce: nonce.isEmpty ? prior?.responseNonce ?? '' : nonce,
      adapterCallbackTokenRef: token.isEmpty
          ? prior?.adapterCallbackTokenRef ?? ''
          : token,
      originEndpointId: origin.isEmpty ? prior?.originEndpointId ?? '' : origin,
    );
  }

  void _pruneSecrets() {
    final retained = _inbox
        .where((item) => item.isPending)
        .map((item) => item.pendingOperationId)
        .toSet();
    _secrets.removeWhere((id, _) => !retained.contains(id));
  }
}

final class _SecureMeshApprovalSecrets {
  const _SecureMeshApprovalSecrets({
    required this.responseNonce,
    required this.adapterCallbackTokenRef,
    required this.originEndpointId,
  });

  final String responseNonce;
  final String adapterCallbackTokenRef;
  final String originEndpointId;
}
