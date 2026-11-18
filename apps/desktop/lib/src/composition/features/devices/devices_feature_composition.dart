import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/devices/devices_controller.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/devices/devices_binding.dart';
import 'package:licoup/src/presentation/devices/devices_effect.dart';
import 'package:licoup/src/presentation/devices/devices_intent.dart';
import 'package:licoup/src/presentation/devices/devices_projection.dart';
import 'package:licoup/src/projections/application_projection_source.dart';
import 'package:licoup/src/projections/devices/devices_projection_producer.dart';

/// Feature-local composition unit for the Devices surface.
final class DevicesFeatureComposition {
  DevicesFeatureComposition(
    DevicesController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _controller = controller,
       _beginRendererIntent = beginRendererIntent {
    _projection = devicesProjectionSource(controller);
    _effects = SemanticEffectChannel<DevicesEffect>();
    binding = DevicesBinding(
      projection: _projection,
      intents: SemanticIntentChannel<DevicesIntent>(_handleIntent),
      effects: _effects,
    );
  }

  final DevicesController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late final ApplicationProjectionSource<DevicesProjection> _projection;
  late final SemanticEffectChannel<DevicesEffect> _effects;
  late final DevicesBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(DevicesIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case RefreshDevices():
        await _report(await _controller.refresh(), null, trace);
      case EnrollDevice(:final station, :final invitation, :final caPem):
        await _report(
          await _controller.enroll(
            station: station,
            invitation: invitation,
            caPem: caPem,
          ),
          DevicesAction.enrolled,
          trace,
        );
      case OfferDevicePairing(:final label):
        await _report(
          await _controller.offerPairing(label: label),
          null,
          trace,
        );
      case CopyDevicePairingCode():
        if (await _controller.copyPairingCode()) {
          _effects.emit(
            DevicesActionCompleted(
              DevicesAction.pairingCodeCopied,
              trace: trace,
            ),
          );
        } else {
          _effects.emit(
            DevicesActionRejected(
              'devices_pairing_code_copy_failed',
              trace: trace,
            ),
          );
        }
      case DismissDevicePairingCode():
        _controller.dismissOffer();
      case ClaimDevicePairing(:final code, :final label):
        await _report(
          await _controller.claimPairing(code: code, label: label),
          DevicesAction.pairingClaimed,
          trace,
        );
      case CancelDevicePairing(:final pairingId):
        await _report(
          await _controller.cancelPairing(pairingId),
          DevicesAction.pairingCancelled,
          trace,
        );
      case UnpairDevice(:final peerId):
        await _report(
          await _controller.unpair(peerId),
          DevicesAction.unpaired,
          trace,
        );
      case SendDeviceMessage(:final peerId, :final agent, :final body):
        await _report(
          await _controller.sendMessage(
            peerId: peerId,
            agent: agent,
            body: body,
          ),
          DevicesAction.messageSent,
          trace,
        );
      case AcknowledgeLegacyPairingNotice():
        await _controller.acknowledgeLegacyPairingNotice();
    }
  }

  Future<void> _report(
    bool succeeded,
    DevicesAction? completed,
    TraceContext? trace,
  ) async {
    if (!succeeded) {
      _effects.emit(DevicesActionRejected(_controller.errorCode, trace: trace));
    } else if (completed != null) {
      _effects.emit(DevicesActionCompleted(completed, trace: trace));
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _projection.dispose();
    await _effects.dispose();
  }
}
