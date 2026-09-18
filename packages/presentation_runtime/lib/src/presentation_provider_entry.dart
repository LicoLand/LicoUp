import 'package:presentation_contract/presentation_contract.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;

import 'presentation_runtime.dart';

/// One runtime per Riverpod container. Automatic retry is disabled here;
/// recovery belongs to the source owner or an explicit user action.
final presentationRuntimeProvider = Provider<PresentationRuntime>((ref) {
  final runtime = PresentationRuntime();
  ref.onDispose(runtime.dispose);
  return runtime;
}, retry: (_, __) => null);

/// Official Riverpod hand-off for one typed presentation resource.
///
/// The provider state is container-scoped and delegates observation,
/// consistency admission, preparation, scheduling, and capacity to the
/// runtime owned by that container.
abstract interface class PresentationProviderEntry<T> {
  ResourceFieldGroup<T> get resource;

  ProviderListenable<AsyncValue<ResourceSnapshot<T>>> get listenable;
}

typedef ResourceProviderEntry<T> = PresentationProviderEntry<T>;

/// Creates the standard Riverpod listenable for one renderer-independent
/// source. The provider is auto-disposed; the container-scoped runtime keeps
/// the source observation shared by multiple listenables in that container.
StreamProvider<ResourceSnapshot<T>> presentationResourceProvider<T>(
  PresentationSource<T> source,
) {
  return StreamProvider.autoDispose<ResourceSnapshot<T>>((ref) {
    final runtime = ref.watch(presentationRuntimeProvider);
    final subscription = runtime.observe(source);
    ref.onDispose(subscription.close);
    return subscription.stream;
  }, retry: (_, __) => null);
}

/// Short application-facing spelling for [presentationResourceProvider].
StreamProvider<ResourceSnapshot<T>> resourceProvider<T>(
  PresentationSource<T> source,
) => presentationResourceProvider(source);

/// A concrete entry that can be handed to a thin Region adapter.
final class BoundPresentationProviderEntry<T>
    implements PresentationProviderEntry<T> {
  BoundPresentationProviderEntry(PresentationSource<T> source)
    : resource = source.fieldGroup,
      listenable = presentationResourceProvider(source);

  @override
  final ResourceFieldGroup<T> resource;

  @override
  final ProviderListenable<AsyncValue<ResourceSnapshot<T>>> listenable;
}

PresentationProviderEntry<T> presentationProviderEntry<T>(
  PresentationSource<T> source,
) => BoundPresentationProviderEntry<T>(source);

PresentationProviderEntry<T> resourceProviderEntry<T>(
  PresentationSource<T> source,
) => presentationProviderEntry(source);
