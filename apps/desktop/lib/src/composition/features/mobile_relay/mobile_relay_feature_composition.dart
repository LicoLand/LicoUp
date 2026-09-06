import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_effect_producer.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_intent_adapter.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/projections/mobile_relay/mobile_relay_projection_producer.dart';

/// Feature-local composition unit consumed by the central composition join.
final class MobileRelayFeatureComposition {
  MobileRelayFeatureComposition({
    required MobileRelayController relay,
    required SecureMeshController secureMesh,
    required MobileHomeLayoutController homeLayout,
    required bool Function() readMobileRuntime,
    RendererIntentTraceFactory? beginRendererIntent,
  }) {
    projection = MobileRelayProjectionProducer(
      relay: relay,
      secureMesh: secureMesh,
      homeLayout: homeLayout,
      readMobileRuntime: readMobileRuntime,
    );
    effects = MobileRelayEffectProducer();
    intents = MobileRelayIntentAdapter(
      relay: relay,
      secureMesh: secureMesh,
      homeLayout: homeLayout,
      effects: effects,
      beginRendererIntent: beginRendererIntent,
    );
    binding = MobileRelayBinding(
      projection: projection,
      intents: intents,
      effects: effects,
    );
  }

  late final MobileRelayProjectionProducer projection;
  late final MobileRelayEffectProducer effects;
  late final MobileRelayIntentAdapter intents;
  late final MobileRelayBinding binding;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await projection.dispose();
    await effects.dispose();
  }
}
