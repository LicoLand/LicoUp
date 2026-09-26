import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';

/// Adapts one conversation plane port to the existing [ProjectionSource] shape.
///
/// A consumer that already speaks [ProjectionSource] reads the plane the
/// runtime admitted instead of the producer channel: a withdrawn plane never
/// hands out the value it showed before, and producer reads that happen while
/// the plane is withdrawn stay invisible until the plane is explicitly
/// re-read. [empty] supplies the value for "nothing is visible"; it is never a
/// cache of the withdrawn one.
final class ConversationPlaneProjectionSource<T>
    implements ProjectionSource<T> {
  ConversationPlaneProjectionSource(this.port, {required T Function() empty})
    : _empty = empty;

  final ConversationPlanePort<T> port;
  final T Function() _empty;

  @override
  T get current => port.visibleValue ?? _empty();

  @override
  Stream<ProjectionUpdate<T>> get changes => port.reads
      .where((read) => read is ConversationPlaneVisible<T>)
      .map(
        (read) =>
            ProjectionUpdate<T>((read as ConversationPlaneVisible<T>).value),
      );
}
