import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

/// Resource scope of conversation message bodies rendered as prepared values.
///
/// One resource is one message body. The identity is the message part the
/// conversation projected, so a later revision of the same message keeps its
/// resource and only advances its version, while a message that leaves the
/// projection is retired and its prepared value is withdrawn.
const ResourceScope conversationMarkdownResourceScope = ResourceScope(
  'licoup.conversation.markdown',
);

/// Field group every message body revision is published as.
const String conversationMarkdownBodyField = 'body';

/// The body field group of one message identity.
///
/// The resource is the message part identity, so two views of the same part
/// share one prepared value and a rebuilt view never re-reads the source.
ResourceFieldGroup<ConversationMarkdownBody> conversationMarkdownFieldGroupFor(
  String identity,
) => ResourceFieldGroup<ConversationMarkdownBody>(
  resource: ResourceKey(
    scope: conversationMarkdownResourceScope,
    stableKey: identity,
  ),
  name: conversationMarkdownBodyField,
);

/// Immutable raw value of one message body revision.
///
/// The value keeps the complete original text. Prepared values cite ranges
/// inside this text, so a view keeps full-body viewing, selection, and copy
/// without any renderer re-parsing or normalizing it.
final class ConversationMarkdownBody {
  const ConversationMarkdownBody({required this.identity, required this.text});

  /// Stable identity of the message body this value belongs to.
  final String identity;

  /// The full original text of the body, exactly as the conversation
  /// projected it.
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConversationMarkdownBody &&
          other.identity == identity &&
          other.text == text;

  @override
  int get hashCode => Object.hash(identity, text);

  @override
  String toString() =>
      'ConversationMarkdownBody($identity, ${text.length} units)';
}

/// One message body source binding.
///
/// The binding owns the latest revision of one body and reports every later
/// revision as a [SourceChange] that carries the consistency group of that
/// revision, so the runtime admits, prepares, and installs it atomically.
/// It never parses: the text is the raw projection output.
final class ConversationMarkdownSource
    implements PresentationSource<ConversationMarkdownBody> {
  ConversationMarkdownSource._({
    required this.fieldGroup,
    required ResourceSnapshot<ConversationMarkdownBody> initial,
    required this.conversationId,
  }) : _current = initial;

  @override
  final ResourceFieldGroup<ConversationMarkdownBody> fieldGroup;

  /// Conversation this body belongs to, when the publisher reported one.
  final String conversationId;

  final StreamController<SourceChange<ConversationMarkdownBody>> _changes =
      StreamController<SourceChange<ConversationMarkdownBody>>.broadcast(
        sync: true,
      );
  ResourceSnapshot<ConversationMarkdownBody> _current;
  bool _retired = false;
  bool _disposed = false;

  /// The revision this binding currently holds.
  ConversationMarkdownBody get current => _current.value;

  /// The whole current revision, for a caller that has to compare positions.
  ResourceSnapshot<ConversationMarkdownBody> get snapshot => _current;

  SourcePosition get position => _current.position;

  bool get retired => _retired;

  /// Publishes [text] as the next revision of this body.
  ///
  /// Returns true when this call produced a new revision. Publishing the text
  /// the binding already holds is a no-op: a rebuild that repeats the same
  /// projection value never re-enters admission or preparation.
  bool publish(String text) {
    if (_disposed || _retired || _current.value.text == text) return false;
    final previous = _current;
    final position = SourcePosition(
      epoch: previous.epoch,
      version: SourceVersion(previous.version.value + 1),
    );
    final group = _groupAt(position);
    final snapshot = ResourceSnapshot<ConversationMarkdownBody>(
      fieldGroup: fieldGroup,
      epoch: position.epoch,
      version: position.version,
      value: ConversationMarkdownBody(
        identity: previous.value.identity,
        text: text,
      ),
      consistencyGroup: group,
    );
    _current = snapshot;
    final change = SourceChange<ConversationMarkdownBody>(
      snapshot: snapshot,
      base: previous.position,
      group: group,
    );
    if (_changes.hasListener) _changes.add(change);
    return true;
  }

  @override
  Future<SourceObservation<ConversationMarkdownBody>> open() async =>
      SourceObservation<ConversationMarkdownBody>(
        initial: _current,
        changes: _changes.stream,
      );

  ConsistencyGroup _groupAt(SourcePosition position) => ConsistencyGroup(
    id: ConsistencyGroupId(
      'conversation-markdown:${fieldGroup.resource.stableKey}',
    ),
    position: position,
    changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
  );

  /// Opens a fresh incarnation of this binding at [epoch].
  ///
  /// The binding object is reused because the runtime owns one observation per
  /// resource field: a rebuilt message reopens its own binding instead of
  /// registering a second source for the same field. The next open reports the
  /// new incarnation as its initial revision, and every value prepared from the
  /// retired one carries the previous epoch, so it can never install again.
  void reopen({required SourceEpoch epoch, required String text}) {
    if (_disposed) return;
    _retired = false;
    _current = ResourceSnapshot<ConversationMarkdownBody>(
      fieldGroup: fieldGroup,
      epoch: epoch,
      version: const SourceVersion(0),
      value: ConversationMarkdownBody(
        identity: fieldGroup.resource.stableKey,
        text: text,
      ),
      consistencyGroup: _groupAt(
        SourcePosition(epoch: epoch, version: const SourceVersion(0)),
      ),
    );
  }

  void retire() {
    if (_disposed) return;
    _retired = true;
    // The binding stays registered for its resource field, so the text a
    // retired message held is dropped here instead of being retained.
    _current = ResourceSnapshot<ConversationMarkdownBody>(
      fieldGroup: fieldGroup,
      epoch: _current.epoch,
      version: _current.version,
      value: ConversationMarkdownBody(
        identity: fieldGroup.resource.stableKey,
        text: '',
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_changes.close());
  }
}

/// Application-scope ownership of the message body bindings one client shows.
///
/// The registry is the conversation read side for prepared markdown: it maps a
/// projected message identity to one stable resource, advances the version on
/// every text revision, and issues a fresh epoch when a retired identity comes
/// back, so nothing prepared from the previous incarnation can install.
final class ConversationMarkdownSourceRegistry {
  ConversationMarkdownSourceRegistry();

  final Map<String, ConversationMarkdownSource> _sources =
      <String, ConversationMarkdownSource>{};
  int _nextEpoch = 0;

  /// Every binding this registry ever published, in first-publish order.
  ///
  /// A retired binding stays registered because the runtime owns one
  /// observation per resource field; its text is empty until it is reopened.
  Iterable<ConversationMarkdownSource> get sources => _sources.values;

  /// The body field group of one message identity.
  ResourceFieldGroup<ConversationMarkdownBody> fieldGroupFor(String identity) =>
      conversationMarkdownFieldGroupFor(identity);

  /// The binding of one identity, when it was published.
  ConversationMarkdownSource? sourceFor(String identity) => _sources[identity];

  /// The revision one identity currently holds, when it was published.
  ConversationMarkdownBody? current(String identity) =>
      _sources[identity]?.current;

  /// Publishes one text revision of [identity].
  ///
  /// Returns the binding when this call changed it, or null when the text is
  /// the revision already held. A retired identity that comes back is reopened
  /// in a new epoch, which makes every value prepared from the retired
  /// incarnation un-installable.
  ConversationMarkdownSource? publish({
    required String identity,
    required String text,
    String conversationId = '',
  }) {
    final existing = _sources[identity];
    if (existing != null) {
      if (existing.retired) {
        existing.reopen(epoch: _newEpoch(), text: text);
        return existing;
      }
      return existing.publish(text) ? existing : null;
    }
    final epoch = _newEpoch();
    final position = SourcePosition(
      epoch: epoch,
      version: const SourceVersion(0),
    );
    final fieldGroup = fieldGroupFor(identity);
    final source = ConversationMarkdownSource._(
      fieldGroup: fieldGroup,
      conversationId: conversationId,
      initial: ResourceSnapshot<ConversationMarkdownBody>(
        fieldGroup: fieldGroup,
        epoch: position.epoch,
        version: position.version,
        value: ConversationMarkdownBody(identity: identity, text: text),
        consistencyGroup: ConsistencyGroup(
          id: ConsistencyGroupId('conversation-markdown:$identity'),
          position: position,
          changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
        ),
      ),
    );
    _sources[identity] = source;
    return source;
  }

  /// Retires one binding and drops the text it held.
  ///
  /// The binding object itself stays registered for its resource field; a later
  /// publish reopens it in a new epoch.
  ConversationMarkdownSource? retire(String identity) {
    final source = _sources[identity];
    source?.retire();
    return source;
  }

  /// Retires every binding, for example when the owning scope ends.
  ///
  /// The bindings stay registered for their resource fields and hold no text.
  void clear() {
    for (final source in _sources.values) {
      source.retire();
    }
  }

  void dispose() {
    for (final source in _sources.values) {
      source.dispose();
    }
  }

  SourceEpoch _newEpoch() =>
      SourceEpoch('conversation-markdown-epoch-${_nextEpoch++}');
}
