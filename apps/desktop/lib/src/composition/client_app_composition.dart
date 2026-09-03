import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/m2_legacy_shell_renderer_transition_adapter.dart';
import 'package:licoup/src/composition/shell_intent_adapter.dart';
import 'package:licoup/src/frontend/binding/frame_timing_telemetry.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/projections/shell/shell_effect_producer.dart';
import 'package:licoup/src/projections/shell/shell_projection_producer.dart';

final class ClientAppComposition {
  ClientAppComposition({
    ClientController? controller,
    FrameTimingTelemetry? telemetry,
  }) : _controller = controller ?? ClientController(),
       _telemetry = telemetry {
    _projection = ShellProjectionProducer(
      shell: _controller.shellController,
      navigation: _controller.navigationController,
      layout: _controller.layoutManager,
      readMobileSurface: () => _controller.mobileClientRuntimePlatform,
    );
    _effects = ShellEffectProducer();
    _intents = ShellIntentAdapter(_controller, _effects);
    binding = ShellBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
    _renderer = M2LegacyShellRendererTransitionAdapter(
      _controller,
      _intents,
      _projection,
    );
    renderer = _renderer;
  }

  final ClientController _controller;
  final FrameTimingTelemetry? _telemetry;
  late final ShellProjectionProducer _projection;
  late final ShellEffectProducer _effects;
  late final ShellIntentAdapter _intents;
  late final M2LegacyShellRendererTransitionAdapter _renderer;
  late final ShellBinding binding;
  late final ShellRendererPort renderer;
  Future<void>? _disposal;

  Future<void> initialize() => _controller.initialize();

  Future<void> initializeLlmGateway() => _controller.initializeLlmGateway();

  void updateConversationAttention({
    AppLifecycleState? lifecycleState,
    bool? viewFocused,
  }) => _controller.updateConversationAttention(
    lifecycleState: lifecycleState,
    viewFocused: viewFocused,
  );

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _renderer.dispose();
    _telemetry?.dispose();
    await _projection.dispose();
    await _effects.dispose();
    _controller.dispose();
  }
}
