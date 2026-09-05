import 'package:presentation_contract/presentation_contract.dart';

sealed class ModelsEffect {
  const ModelsEffect({this.trace});

  final TraceContext? trace;
}

final class ModelAuthorizationRequired extends ModelsEffect {
  const ModelAuthorizationRequired(
    this.providerId,
    this.explanation, {
    super.trace,
  });

  final String providerId;
  final String explanation;
}

final class SensitiveInputAccepted extends ModelsEffect {
  const SensitiveInputAccepted(this.inputKind, {super.trace});

  final String inputKind;
}

final class ModelsActionRejected extends ModelsEffect {
  const ModelsActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}
