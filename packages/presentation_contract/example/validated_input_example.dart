import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'author_support.dart';

final class ValidatedInputInputs {
  const ValidatedInputInputs({
    required this.scope,
    required this.text,
    this.error,
  });

  final ResourceScope scope;
  final String text;
  final ExampleError? error;

  bool get isValid => error == null;
}

sealed class ValidatedInputAction {
  const ValidatedInputAction();
}

final class UpdateInputText extends ValidatedInputAction {
  const UpdateInputText(this.text);

  final String text;
}

final class SubmitInput extends ValidatedInputAction {
  const SubmitInput();
}

final class ValidatedInputActions {
  const ValidatedInputActions({
    required this.origin,
    required this.update,
    required this.submit,
  });

  final ActionOrigin origin;
  final FutureOr<void> Function(String text) update;
  final FutureOr<void> Function() submit;
}

final class ValidatedInputActionLog {
  String? lastSubmittedText;
}

final class ValidatedInputExampleResult {
  const ValidatedInputExampleResult({
    required this.inputs,
    required this.actions,
    required this.actionLog,
  });

  final ValidatedInputInputs inputs;
  final ValidatedInputActions actions;
  final ValidatedInputActionLog actionLog;
}

ValidatedInputExampleResult buildValidatedInputExample() {
  final scope = const ResourceScope('settings:synthetic');
  final resource = ResourceKey(scope: scope, stableKey: 'display-name');
  final error = ExampleError(
    attribution: ExampleErrorAttribution(
      scope: scope,
      resource: resource,
      operation: 'display-name.validate',
    ),
    message: 'Display names need at least four characters.',
  );
  final inputs = ValidatedInputInputs(scope: scope, text: 'lic', error: error);

  final actionLog = ValidatedInputActionLog();
  final callback = CallbackActions<ValidatedInputAction>(
    origin: ActionOrigin(scope: scope, resource: resource),
    onDispatch: (action, origin) {
      if (origin.scope != inputs.scope) {
        throw StateError('input action crossed its originating scope');
      }
      switch (action) {
        case UpdateInputText(:final text):
          if (text.isEmpty) throw StateError('synthetic input cannot be empty');
        case SubmitInput():
          actionLog.lastSubmittedText = inputs.text;
      }
    },
  );
  final actions = ValidatedInputActions(
    origin: callback.origin,
    update: (text) => callback.dispatch(UpdateInputText(text)),
    submit: () => callback.dispatch(const SubmitInput()),
  );

  return ValidatedInputExampleResult(
    inputs: inputs,
    actions: actions,
    actionLog: actionLog,
  );
}

void main() {
  final result = buildValidatedInputExample();
  result.actions.update('lico');
  result.actions.submit();

  if (result.actionLog.lastSubmittedText != 'lic') {
    throw StateError('typed input actions were not delivered');
  }
  final error = result.inputs.error;
  if (result.inputs.isValid ||
      error == null ||
      error.attribution.scope != result.inputs.scope ||
      error.attribution.resource == null) {
    throw StateError('validation error lost its scope or resource attribution');
  }

  print('input valid: ${result.inputs.isValid}');
  print('validation operation: ${error.attribution.operation}');
  print('validation message: ${error.message}');
}
