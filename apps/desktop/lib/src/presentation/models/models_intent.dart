import 'package:presentation_contract/presentation_contract.dart';

sealed class ModelsIntent {
  const ModelsIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshModels extends ModelsIntent {
  const RefreshModels({super.trace});
}

final class RefreshGateway extends ModelsIntent {
  const RefreshGateway({super.trace});
}

final class SetGatewayEnabled extends ModelsIntent {
  const SetGatewayEnabled(this.enabled, {super.trace});

  final bool enabled;
}

final class SaveGatewayEndpoint extends ModelsIntent {
  const SaveGatewayEndpoint(this.endpoint, {super.trace});

  final String endpoint;
}

final class SelectGatewayModel extends ModelsIntent {
  const SelectGatewayModel(this.providerId, this.modelId, {super.trace});

  final String providerId;
  final String modelId;
}

final class AuthorizeModelProvider extends ModelsIntent {
  const AuthorizeModelProvider(this.providerId, {super.trace});

  final String providerId;
}

final class RecoverModelGateway extends ModelsIntent {
  const RecoverModelGateway({super.trace});
}

final class RefreshGatewayCredentials extends ModelsIntent {
  const RefreshGatewayCredentials({super.trace});
}

final class CreateGatewayCredential extends ModelsIntent {
  const CreateGatewayCredential({
    required this.provider,
    required this.label,
    required this.apiKey,
    required this.leaseDays,
    super.trace,
  });

  final String provider;
  final String label;
  final String apiKey;
  final int leaseDays;
}

final class UpdateGatewayCredential extends ModelsIntent {
  const UpdateGatewayCredential({
    required this.credentialId,
    this.label,
    this.extendDays,
    super.trace,
  });

  final String credentialId;
  final String? label;
  final int? extendDays;
}

final class DeleteGatewayCredential extends ModelsIntent {
  const DeleteGatewayCredential(this.credentialId, {super.trace});

  final String credentialId;
}

final class SetGatewayCredentialAuthorized extends ModelsIntent {
  const SetGatewayCredentialAuthorized(
    this.credentialId,
    this.authorized, {
    super.trace,
  });

  final String credentialId;
  final bool authorized;
}

final class AuthorizeAllGatewayCredentials extends ModelsIntent {
  const AuthorizeAllGatewayCredentials({super.trace});
}

final class RefreshTelegramChannel extends ModelsIntent {
  const RefreshTelegramChannel({super.trace});
}

final class SaveTelegramToken extends ModelsIntent {
  const SaveTelegramToken(this.token, {super.trace});

  final String token;
}

final class ClearTelegramToken extends ModelsIntent {
  const ClearTelegramToken({super.trace});
}

final class ApproveTelegramPairing extends ModelsIntent {
  const ApproveTelegramPairing(this.code, {super.trace});

  final String code;
}

final class RevokeTelegramChat extends ModelsIntent {
  const RevokeTelegramChat(this.chatId, {super.trace});

  final int chatId;
}
