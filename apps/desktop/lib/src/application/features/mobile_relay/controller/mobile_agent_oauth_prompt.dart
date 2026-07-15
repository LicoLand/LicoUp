part of 'package:flutter_client/src/application/controller/client_controller.dart';

enum MobileAgentOAuthAuthorizationPromptStatus {
  waiting,
  failed,
  success,
  dismissed,
}

class MobileAgentOAuthAuthorizationPrompt {
  const MobileAgentOAuthAuthorizationPrompt({
    required this.providerId,
    required this.mobileAccountId,
    required this.status,
    required this.updatedAt,
    this.message = '',
  });

  final String providerId;
  final String mobileAccountId;
  final MobileAgentOAuthAuthorizationPromptStatus status;
  final DateTime updatedAt;
  final String message;

  bool get isWaiting =>
      status == MobileAgentOAuthAuthorizationPromptStatus.waiting;
  bool get isFailed =>
      status == MobileAgentOAuthAuthorizationPromptStatus.failed;
  bool get isSuccess =>
      status == MobileAgentOAuthAuthorizationPromptStatus.success;
  bool get isDismissed =>
      status == MobileAgentOAuthAuthorizationPromptStatus.dismissed;

  MobileAgentOAuthAuthorizationPrompt copyWith({
    MobileAgentOAuthAuthorizationPromptStatus? status,
    DateTime? updatedAt,
    String? message,
  }) {
    return MobileAgentOAuthAuthorizationPrompt(
      providerId: providerId,
      mobileAccountId: mobileAccountId,
      status: status ?? this.status,
      updatedAt: updatedAt ?? this.updatedAt,
      message: message ?? this.message,
    );
  }
}
