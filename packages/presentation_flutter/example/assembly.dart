import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override, ProviderListenable;
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

/// Synthetic source used by the assembly example. It has no process or
/// application dependency and demonstrates the contract's source boundary.
final class SyntheticMessageSource implements PresentationSource<String> {
  static final resource = ResourceFieldGroup<String>(
    resource: ResourceKey(
      scope: const ResourceScope('conversation:synthetic'),
      stableKey: 'message-1',
    ),
    name: 'body',
  );

  static const position = SourcePosition(
    epoch: SourceEpoch('synthetic-epoch'),
    version: SourceVersion(1),
  );

  static final group = ConsistencyGroup(
    id: const ConsistencyGroupId('synthetic-group'),
    position: position,
    changed: <ChangedFieldGroup>[ChangedFieldGroup.of(resource)],
  );

  static final snapshot = ResourceSnapshot<String>(
    fieldGroup: resource,
    epoch: position.epoch,
    version: position.version,
    value: 'Synthetic message',
    consistencyGroup: group,
  );

  @override
  ResourceFieldGroup<String> get fieldGroup => resource;

  ResourceSnapshot<String> get initial => snapshot;

  @override
  Future<SourceObservation<String>> open() async => SourceObservation<String>(
    initial: snapshot,
    changes: Stream<SourceChange<String>>.empty(),
  );
}

final syntheticMessageSource = SyntheticMessageSource();

/// Ordinary, renderer-independent component inputs.
final class MessageBodyInputs {
  const MessageBodyInputs({required this.document});

  final String document;
}

/// Ordinary component actions; the originating scope is owned by the caller.
final class MessageBodyActions {
  const MessageBodyActions({required this.copy});

  final void Function() copy;
}

final messageBodyProvider = Provider<MessageBodyInputs>((ref) {
  return MessageBodyInputs(document: syntheticMessageSource.initial.value);
});

/// Component declaration assembled with a stable provider and typed actions.
final class MessageBodyRegion
    implements Region<MessageBodyInputs, MessageBodyActions> {
  const MessageBodyRegion({
    required this.source,
    required this.actions,
    required this.render,
  });

  @override
  final ProviderListenable<MessageBodyInputs> source;

  @override
  final MessageBodyActions actions;

  @override
  final RegionRenderer<MessageBodyInputs, MessageBodyActions> render;
}

final messageBodyRegion = MessageBodyRegion(
  source: messageBodyProvider,
  actions: MessageBodyActions(copy: () {}),
  render: (context, inputs, actions) =>
      GestureDetector(onTap: actions.copy, child: Text(inputs.document)),
);

/// Compileable ProviderScope override assembly for the synthetic source.
Widget buildSyntheticAssembly() => ProviderScope(
  overrides: <Override>[
    messageBodyProvider.overrideWithValue(
      MessageBodyInputs(document: syntheticMessageSource.initial.value),
    ),
  ],
  child: _RegionHost(region: messageBodyRegion),
);

final class _RegionHost extends ConsumerWidget {
  const _RegionHost({required this.region});

  final Region<MessageBodyInputs, MessageBodyActions> region;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inputs = ref.watch(region.source);
    return region.render(context, inputs, region.actions);
  }
}
