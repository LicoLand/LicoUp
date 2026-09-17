import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart' show ProviderListenable;
import 'package:test/test.dart';

final class _Entry implements PresentationProviderEntry<String> {
  _Entry(this.resource, ResourceSnapshot<String> snapshot)
    : listenable = Provider<AsyncValue<ResourceSnapshot<String>>>(
        (ref) => AsyncValue<ResourceSnapshot<String>>.data(snapshot),
      );

  @override
  final ResourceFieldGroup<String> resource;

  @override
  final ProviderListenable<AsyncValue<ResourceSnapshot<String>>> listenable;
}

void main() {
  test('runtime exposes an official ProviderListenable entry', () {
    final key = ResourceKey(
      scope: const ResourceScope('synthetic'),
      stableKey: 'message-1',
    );
    final fieldGroup = ResourceFieldGroup<String>(resource: key, name: 'body');
    final snapshot = ResourceSnapshot<String>(
      fieldGroup: fieldGroup,
      epoch: const SourceEpoch('epoch-a'),
      version: const SourceVersion(1),
      value: 'synthetic',
    );
    final entry = _Entry(fieldGroup, snapshot);

    expect(entry.resource, fieldGroup);
    expect(
      entry.listenable,
      isA<ProviderListenable<AsyncValue<ResourceSnapshot<String>>>>(),
    );
  });
}
