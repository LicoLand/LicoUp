import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'author_support.dart';

/// Renderer-local input state.
///
/// The echo of what the user is typing stays here. It is not a source, it is
/// not merged, and it cannot invalidate a prepared value; only the explicit
/// submit crosses into the application.
final class ValidatedInputDraft {
  const ValidatedInputDraft({required this.text, required this.pending});

  final String text;
  final bool pending;

  ValidatedInputDraft edit(String next) =>
      ValidatedInputDraft(text: next, pending: true);

  ValidatedInputDraft settled() =>
      ValidatedInputDraft(text: text, pending: false);
}

/// Plain host input for the form primitive: ordinary field descriptors.
final class ValidatedInputFieldSpec {
  const ValidatedInputFieldSpec({
    required this.id,
    required this.label,
    required this.kind,
    required this.required,
  });

  final String id;
  final String label;
  final String kind;
  final bool required;
}

final class ValidatedInputFormInputs {
  const ValidatedInputFormInputs({
    required this.title,
    required this.fields,
    required this.values,
  });

  final String title;
  final List<ValidatedInputFieldSpec> fields;
  final Map<String, String> values;
}

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
  int updateCount = 0;
}

final class ValidatedInputExampleResult {
  const ValidatedInputExampleResult({
    required this.inputs,
    required this.actions,
    required this.form,
    required this.command,
    required this.draft,
    required this.prepared,
    required this.actionLog,
  });

  final ValidatedInputInputs inputs;
  final ValidatedInputActions actions;
  final DeclarativeInput<ValidatedInputFormInputs, ValidatedInputAction> form;
  final DeclarativeInput<Map<String, String>, ValidatedInputAction> command;
  final ValidatedInputDraft draft;

  /// Prepared value the submitted text was read from.
  final PreparedValue<String> prepared;

  final ValidatedInputActionLog actionLog;
}

ValidatedInputExampleResult buildValidatedInputExample() {
  final scope = const ResourceScope('settings:synthetic');
  final resource = ResourceKey(scope: scope, stableKey: 'display-name');
  final position = const SourcePosition(
    epoch: SourceEpoch('settings-epoch'),
    version: SourceVersion(2),
  );
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
          actionLog.updateCount++;
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

  // Typing echoes locally; the submitted value keeps its prepared position.
  final draft = const ValidatedInputDraft(
    text: '',
    pending: false,
  ).edit('lico').settled();

  final content = ContentRevision(
    resource: resource,
    position: position,
    blocks: <SourceBlock>[
      SourceBlock(
        id: const BlockId('display-name'),
        version: const BlockVersion(1),
        text: SourceTextReference(
          resource: resource,
          position: position,
          range: const SourceTextRange(start: 0, end: 3),
        ),
        isSealed: true,
      ),
    ],
  );
  final prepared = PreparedValue<String>.fromBlocks(
    key: PreparationKey(
      parserVersion: const ParserVersion('settings-markdown@1'),
      syntaxConfig: SyntaxConfig(revision: 'settings-syntax@1'),
      content: content,
    ),
    blocks: <PreparedBlock<String>>[
      PreparedBlock<String>(
        block: content.blocks.single,
        value: 'display name: ${inputs.text}',
      ),
    ],
  );

  final form = DeclarativeInput<ValidatedInputFormInputs, ValidatedInputAction>(
    contributionId: 'vendor.example.display-name-form',
    primitive: DeclarativePrimitive.form,
    resource: resource,
    inputs: ValidatedInputFormInputs(
      title: 'Display name',
      fields: const <ValidatedInputFieldSpec>[
        ValidatedInputFieldSpec(
          id: 'display-name',
          label: 'Display name',
          kind: 'text',
          required: true,
        ),
        ValidatedInputFieldSpec(
          id: 'display-name-secret',
          label: 'Directory key',
          kind: 'secret-ref',
          required: false,
        ),
      ],
      values: <String, String>{'display-name': inputs.text},
    ),
    actions: callback,
    position: position,
  );
  final command = DeclarativeInput<Map<String, String>, ValidatedInputAction>(
    contributionId: 'vendor.example.save-display-name',
    primitive: DeclarativePrimitive.command,
    resource: resource,
    inputs: const <String, String>{'operation': 'save-display-name'},
    actions: callback,
    position: position,
  );

  return ValidatedInputExampleResult(
    inputs: inputs,
    actions: actions,
    form: form,
    command: command,
    draft: draft,
    prepared: prepared,
    actionLog: actionLog,
  );
}

void main() {
  final result = buildValidatedInputExample();
  result.actions.update(result.draft.text);
  result.actions.submit();

  if (result.actionLog.lastSubmittedText != 'lic' ||
      result.actionLog.updateCount != 1) {
    throw StateError('typed input actions were not delivered');
  }
  // The local echo carries no source position, and the prepared value still
  // matches the position the form and the command were declared from.
  if (result.draft.pending ||
      result.draft.text != 'lico' ||
      result.prepared.position != result.form.position ||
      result.prepared.position != result.command.position) {
    throw StateError('local input state changed the prepared source position');
  }
  final error = result.inputs.error;
  if (result.inputs.isValid ||
      error == null ||
      error.attribution.scope != result.inputs.scope ||
      error.attribution.resource == null) {
    throw StateError('validation error lost its scope or resource attribution');
  }
  if (result.form.isSupportedBy(<DeclarativePrimitive>[
            DeclarativePrimitive.form,
          ]) !=
          true ||
      result.command.unavailableGiven(<DeclarativePrimitive>[
            DeclarativePrimitive.form,
          ]) ==
          null) {
    throw StateError('declarative inputs ignored the shell primitive set');
  }

  print('input valid: ${result.inputs.isValid}');
  print('local draft text: ${result.draft.text}');
  print('form fields: ${result.form.inputs.fields.length}');
  print('command state: ${result.command.inputs['operation']}');
  print('validation operation: ${error.attribution.operation}');
}
