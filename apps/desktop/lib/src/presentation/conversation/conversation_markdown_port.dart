import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';
import 'package:riverpod/riverpod.dart';

/// Why a prepared conversation message body stopped being visible.
///
/// A bounded cache decision and a withdrawn authority are different facts: a
/// retired body's input text is still the conversation's own read, while a
/// revoked body's content must stop being visible until a later controlled
/// input opens a fresh incarnation.
enum ConversationMarkdownWithdrawal {
  /// Bounded retention or an explicit owner retire dropped the value. The
  /// view may show its legitimate local-loading presentation and a later
  /// controlled input may prepare the body again.
  retired,

  /// The application withdrew authority over the body. The content must not be
  /// visible again from a repeated read; only a later controlled input may
  /// open a fresh incarnation.
  revoked,

  /// The preparation scope ended. Nothing may be shown from it.
  scopeEnded,
}

/// The current state of one conversation message body.
sealed class ConversationMarkdownBodyState {
  const ConversationMarkdownBodyState();
}

/// No preparation is configured for this container.
final class ConversationMarkdownUnavailable
    extends ConversationMarkdownBodyState {
  const ConversationMarkdownUnavailable();
}

/// Preparation is configured; no value is installed for this body yet.
final class ConversationMarkdownPreparing extends ConversationMarkdownBodyState {
  const ConversationMarkdownPreparing();
}

/// The prepared value of this body is installed and visible.
final class ConversationMarkdownInstalled extends ConversationMarkdownBodyState {
  const ConversationMarkdownInstalled(this.value);

  final PreparedValue<MessageMarkdownBlock> value;
}

/// Nothing is visible for this body because it was withdrawn.
final class ConversationMarkdownWithdrawn extends ConversationMarkdownBodyState {
  const ConversationMarkdownWithdrawn(this.reason);

  final ConversationMarkdownWithdrawal reason;
}

/// Narrow port the conversation message view consumes for prepared markdown.
///
/// The view publishes the text it currently holds and reads or follows the
/// prepared state of its own message identity. The port exposes no lifecycle
/// owner: the runtime, the worker pool, the source registry, and the
/// preparation scheduling live behind an implementation bound by composition,
/// so the stable presentation plane stays free of implementation state.
abstract interface class ConversationMarkdownPort {
  /// Publishes the text a view currently holds for one message body.
  ///
  /// Returns the position the body is at after this call, or null when no
  /// preparation is available. A view compares the position of an installed
  /// value with this position, so a value prepared from an older revision of
  /// the same body is never rendered against newer text. Repeating the input
  /// a withdrawal was recorded for never re-enters preparation by itself.
  SourcePosition? publish({
    required String identity,
    required String text,
    String conversationId = '',
  });

  /// The state of one message body, for a synchronous read in build.
  ConversationMarkdownBodyState stateFor(String identity);

  /// Subscribes [listener] to one body's state changes.
  ///
  /// Returns the release function for this subscription. The listener is
  /// called only for later changes; the current state is read with [stateFor].
  void Function() watch(
    String identity,
    void Function(ConversationMarkdownBodyState state) listener,
  );
}

/// The port used when composition has not bound a preparation owner.
///
/// A view renders the text it already holds, unparsed: no preparation is
/// available, and nothing is parsed on the rendering path. Wiring the real
/// owner is a composition decision, not a view decision.
final class DisabledConversationMarkdownPort implements ConversationMarkdownPort {
  const DisabledConversationMarkdownPort();

  @override
  SourcePosition? publish({
    required String identity,
    required String text,
    String conversationId = '',
  }) => null;

  @override
  ConversationMarkdownBodyState stateFor(String identity) =>
      const ConversationMarkdownUnavailable();

  @override
  void Function() watch(
    String identity,
    void Function(ConversationMarkdownBodyState state) listener,
  ) => () {};
}

/// The conversation prepared-markdown port bound by composition.
///
/// Composition overrides this provider with the projection-layer preparation
/// owner over the container's presentation runtime. Without that binding the
/// disabled port keeps every view on its own text.
final conversationMarkdownPortProvider = Provider<ConversationMarkdownPort>(
  (ref) => const DisabledConversationMarkdownPort(),
  retry: (_, _) => null,
);
