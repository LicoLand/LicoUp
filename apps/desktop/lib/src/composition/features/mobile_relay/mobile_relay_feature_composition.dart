import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_effect_producer.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_intent_adapter.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';
import 'package:licoup/src/projections/mobile_relay/mobile_relay_presentation_sources.dart';
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
    _pairingSource = mobileRelayRegionPresentationSource(
      mobileRelayPairingRegion,
      projection,
    );
    _trustSource = mobileRelayRegionPresentationSource(
      mobileRelayTrustRegion,
      projection,
    );
    _approvalsSource = mobileRelayRegionPresentationSource(
      mobileRelayApprovalsRegion,
      projection,
    );
    _transfersSource = mobileRelayRegionPresentationSource(
      mobileRelayTransfersRegion,
      projection,
    );
    _capabilitiesSource = mobileRelayRegionPresentationSource(
      mobileRelayCapabilitiesRegion,
      projection,
    );
    _homeSource = mobileRelayRegionPresentationSource(
      mobileRelayHomeRegion,
      projection,
    );
    providerOverrides = <Override>[
      mobileRelayPairingSourceProvider.overrideWithValue(_pairingSource),
      mobileRelayTrustSourceProvider.overrideWithValue(_trustSource),
      mobileRelayApprovalsSourceProvider.overrideWithValue(_approvalsSource),
      mobileRelayTransfersSourceProvider.overrideWithValue(_transfersSource),
      mobileRelayCapabilitiesSourceProvider.overrideWithValue(
        _capabilitiesSource,
      ),
      mobileRelayHomeSourceProvider.overrideWithValue(_homeSource),
    ];
  }

  late final MobileRelayProjectionProducer projection;
  late final MobileRelayEffectProducer effects;
  late final MobileRelayIntentAdapter intents;
  late final MobileRelayBinding binding;

  late final MobileRelayRegionPresentationSource<MobileRelayPairingInputs>
  _pairingSource;
  late final MobileRelayRegionPresentationSource<MobileRelayTrustInputs>
  _trustSource;
  late final MobileRelayRegionPresentationSource<MobileRelayApprovalsInputs>
  _approvalsSource;
  late final MobileRelayRegionPresentationSource<MobileRelayTransfersInputs>
  _transfersSource;
  late final MobileRelayRegionPresentationSource<MobileRelayCapabilitiesInputs>
  _capabilitiesSource;
  late final MobileRelayRegionPresentationSource<MobileRelayHomeInputs>
  _homeSource;

  /// Riverpod overrides that supply this feature's live presentation sources.
  /// The root ProviderScope (F01.7) and feature tests install them; the legacy
  /// [binding] remains for the consumers that have not migrated yet.
  late final List<Override> providerOverrides;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _pairingSource.dispose();
    await _trustSource.dispose();
    await _approvalsSource.dispose();
    await _transfersSource.dispose();
    await _capabilitiesSource.dispose();
    await _homeSource.dispose();
    await projection.dispose();
    await effects.dispose();
  }
}
