/// Activity chrome for agent conversation tabs.
///
/// Default is [none] (no light). Lights are reserved for actionable or
/// recently completed attention — not online/detected readiness.
enum AgentConversationTabActivity {
  /// No notable event — hide the status light.
  none,

  /// Awaiting user approval / permission / confirmation.
  needsApproval,

  /// A turn finished successfully and has not been acknowledged yet.
  workFinished,
}

/// True when a native/runtime send payload reports user interaction is required.
bool agentConversationResultNeedsApproval(Map<String, dynamic> result) {
  final error = result['error'];
  if (error is Map) {
    if (error['userInteractionRequired'] == true) {
      return true;
    }
    if (_looksLikeUserInteractionCode((error['code'] ?? '').toString())) {
      return true;
    }
    if (_looksLikeApprovalTurnStatus((error['turnStatus'] ?? '').toString())) {
      return true;
    }
  }
  if (_looksLikeUserInteractionCode((result['code'] ?? '').toString())) {
    return true;
  }
  return _looksLikeApprovalTurnStatus((result['turnStatus'] ?? '').toString());
}

bool _looksLikeUserInteractionCode(String code) {
  final normalized = code.trim().toLowerCase();
  return normalized.contains('user_interaction');
}

bool _looksLikeApprovalTurnStatus(String status) {
  final normalized = status.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return normalized == 'userinteractionrequired' ||
      normalized == 'awaitingapproval' ||
      normalized == 'waitingforapproval' ||
      normalized == 'needsapproval';
}
