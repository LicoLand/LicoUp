import 'package:presentation_contract/presentation_contract.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;

/// Official Riverpod hand-off for one typed presentation resource.
///
/// This is an entry declaration only. Source observation, preparation,
/// scheduling, capacity, and installation are implemented by the later
/// runtime slice.
abstract interface class PresentationProviderEntry<T> {
  ResourceFieldGroup<T> get resource;

  ProviderListenable<AsyncValue<ResourceSnapshot<T>>> get listenable;
}

typedef ResourceProviderEntry<T> = PresentationProviderEntry<T>;
