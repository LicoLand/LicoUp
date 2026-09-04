import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/projections/shell/shell_effect_producer.dart';

final class ShellIntentAdapter implements IntentSink<ShellIntent> {
  const ShellIntentAdapter(
    this._controller,
    this._effects, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final ShellEffectProducer _effects;
  final RendererIntentTraceFactory? _beginRendererIntent;

  @override
  void send(ShellIntent intent) {
    final intentTrace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case SelectShellDestination(:final destination):
        if (_controller.currentSection == destination) {
          _effects.emit(
            ShellDestinationReselected(destination, trace: intentTrace),
          );
        }
        _controller.selectSection(
          destination,
          cause: applicationCauseForTrace(intentTrace),
        );
      case UpdateShellLayoutEnvironment(:final environment):
        _controller.layoutManager.updateEnvironment(
          environment,
          cause: applicationCauseForTrace(intentTrace),
        );
      case OpenShellAgent(:final agentId):
        unawaited(_controller.selectConversationAgent(agentId));
        _controller.selectSection(
          ClientSection.agents,
          cause: applicationCauseForTrace(intentTrace),
        );
    }
  }
}
