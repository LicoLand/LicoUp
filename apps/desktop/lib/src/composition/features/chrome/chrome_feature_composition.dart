import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/chrome/chrome_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_effect.dart';
import 'package:licoup/src/presentation/chrome/chrome_intent.dart';
import 'package:licoup/src/projections/chrome/chrome_projection_producer.dart';

final class ChromeFeatureComposition {
  ChromeFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _projection = ChromeProjectionProducer(controller),
       _effects = _ChromeEffects(),
       _intents = _ChromeIntents(
         controller,
         beginRendererIntent: beginRendererIntent,
       ) {
    _intents.effects = _effects;
    binding = ChromeBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final ChromeProjectionProducer _projection;
  final _ChromeEffects _effects;
  final _ChromeIntents _intents;
  late final ChromeBinding binding;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _projection.close();
    await _effects.close();
  }
}

final class _ChromeEffects implements EffectSource<ChromeEffect> {
  final StreamController<ChromeEffect> _controller =
      StreamController<ChromeEffect>.broadcast(sync: true);

  @override
  Stream<ChromeEffect> get effects => _controller.stream;

  void add(ChromeEffect effect) => _controller.add(effect);

  Future<void> close() => _controller.close();
}

final class _ChromeIntents implements IntentSink<ChromeIntent> {
  _ChromeIntents(
    this._controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late _ChromeEffects effects;

  @override
  void send(ChromeIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case SelectChromeDestination(:final destination):
        final previous = _controller.currentSection;
        _controller.selectSection(destination);
        if (previous == destination) {
          effects.add(ChromeDestinationReselected(destination, trace: trace));
        }
      case SetAuxiliaryPanelOpen():
        // Renderer-local panel state does not mutate Application state.
        break;
      case ShowChromeSearch():
        effects.add(ChromeSearchRequested(trace: trace));
      case ShowChromeNotifications():
        effects.add(ChromeNotificationsRequested(trace: trace));
      case DismissChromeNotification(:final notificationId):
        _controller.messagingNotificationCenter.dismiss(notificationId);
      case RecoverChromeGateway():
        unawaited(_controller.llmGatewayLifecycleController.restart());
      case OpenChromeAgentConversation(:final agentId, :final sessionId):
        unawaited(_openAgentConversation(agentId, sessionId));
    }
  }

  Future<void> _openAgentConversation(String agentId, String sessionId) async {
    _controller.selectSection(ClientSection.agents);
    if (_controller.selectedConversationAgentId != agentId) {
      await _controller.selectConversationAgent(agentId);
    }
    if (sessionId.isNotEmpty) {
      _controller.selectConversationSession(sessionId);
    }
  }
}
