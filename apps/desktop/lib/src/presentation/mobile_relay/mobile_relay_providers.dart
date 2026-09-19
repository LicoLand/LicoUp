import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';

/// Static feature providers for the mobile relay presentation regions.
///
/// Source ports are composition inputs: [MobileRelayFeatureComposition]
/// overrides each source provider with the live application adapter. Views
/// watch the typed inputs providers only. Observation opens lazily while a
/// region has a listener and releases with the last one (autoDispose).
PresentationSource<T> _unavailableSource<T>(String region) {
  throw StateError('mobile-relay $region source is supplied by composition');
}

StreamProvider<ResourceSnapshot<T>> _snapshotProvider<T>(
  Provider<PresentationSource<T>> sourceProvider,
) {
  return StreamProvider.autoDispose<ResourceSnapshot<T>>((ref) {
    final runtime = ref.watch(presentationRuntimeProvider);
    final subscription = runtime.observe(ref.watch(sourceProvider));
    ref.onDispose(subscription.close);
    return subscription.stream;
  }, retry: (_, _) => null);
}

Provider<AsyncValue<T>> _inputsProvider<T>(
  StreamProvider<ResourceSnapshot<T>> snapshotProvider,
) {
  return Provider.autoDispose<AsyncValue<T>>(
    (ref) => ref.watch(snapshotProvider).whenData((snapshot) => snapshot.value),
  );
}

final mobileRelayPairingSourceProvider =
    Provider<PresentationSource<MobileRelayPairingInputs>>(
      (_) => _unavailableSource('pairing'),
    );

final mobileRelayPairingSnapshotProvider = _snapshotProvider(
  mobileRelayPairingSourceProvider,
);

final mobileRelayPairingInputsProvider = _inputsProvider(
  mobileRelayPairingSnapshotProvider,
);

final mobileRelayTrustSourceProvider =
    Provider<PresentationSource<MobileRelayTrustInputs>>(
      (_) => _unavailableSource('trust'),
    );

final mobileRelayTrustSnapshotProvider = _snapshotProvider(
  mobileRelayTrustSourceProvider,
);

final mobileRelayTrustInputsProvider = _inputsProvider(
  mobileRelayTrustSnapshotProvider,
);

final mobileRelayApprovalsSourceProvider =
    Provider<PresentationSource<MobileRelayApprovalsInputs>>(
      (_) => _unavailableSource('approvals'),
    );

final mobileRelayApprovalsSnapshotProvider = _snapshotProvider(
  mobileRelayApprovalsSourceProvider,
);

final mobileRelayApprovalsInputsProvider = _inputsProvider(
  mobileRelayApprovalsSnapshotProvider,
);

final mobileRelayTransfersSourceProvider =
    Provider<PresentationSource<MobileRelayTransfersInputs>>(
      (_) => _unavailableSource('transfers'),
    );

final mobileRelayTransfersSnapshotProvider = _snapshotProvider(
  mobileRelayTransfersSourceProvider,
);

final mobileRelayTransfersInputsProvider = _inputsProvider(
  mobileRelayTransfersSnapshotProvider,
);

final mobileRelayCapabilitiesSourceProvider =
    Provider<PresentationSource<MobileRelayCapabilitiesInputs>>(
      (_) => _unavailableSource('capabilities'),
    );

final mobileRelayCapabilitiesSnapshotProvider = _snapshotProvider(
  mobileRelayCapabilitiesSourceProvider,
);

final mobileRelayCapabilitiesInputsProvider = _inputsProvider(
  mobileRelayCapabilitiesSnapshotProvider,
);

final mobileRelayHomeSourceProvider =
    Provider<PresentationSource<MobileRelayHomeInputs>>(
      (_) => _unavailableSource('home'),
    );

final mobileRelayHomeSnapshotProvider = _snapshotProvider(
  mobileRelayHomeSourceProvider,
);

final mobileRelayHomeInputsProvider = _inputsProvider(
  mobileRelayHomeSnapshotProvider,
);
