import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/projections/shell/shell_effect_producer.dart';

final class ShellIntentAdapter implements IntentSink<ShellIntent> {
  const ShellIntentAdapter(this._controller, this._effects);

  final ClientController _controller;
  final ShellEffectProducer _effects;

  @override
  void send(ShellIntent intent) {
    switch (intent) {
      case SelectShellDestination(:final destination, :final trace):
        if (_controller.currentSection == destination) {
          _effects.emit(ShellDestinationReselected(destination, trace: trace));
        }
        _controller.selectSection(destination);
      case UpdateShellLayoutEnvironment(:final environment):
        _controller.layoutManager.updateEnvironment(environment);
      case OpenShellAgent(:final agentId):
        unawaited(_controller.selectConversationAgent(agentId));
        _controller.selectSection(ClientSection.agents);
    }
  }
}
