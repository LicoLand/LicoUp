import 'package:licoup/src/contracts/presentation/mounted_destination_set.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class NavigationProjection {
  NavigationProjection({
    required this.destination,
    required Iterable<ClientSection> destinations,
    Iterable<ClientSection> unavailable = const <ClientSection>[],
    this.recoveryDestination,
  }) : destinations = immutablePresentationList(destinations),
       unavailable = immutablePresentationList(unavailable);

  /// The destination the shell serves now.
  ///
  /// A request for an unmounted destination is already recovered here, so this
  /// value is always one of [destinations].
  final ClientSection destination;

  /// The mounted destinations the shell may offer, in canonical order.
  final List<ClientSection> destinations;

  /// The capabilities this client does not mount, in canonical order.
  ///
  /// The truthful absence report: each entry names a semantic destination whose
  /// feature composition the declaration does not include, so the shell has no
  /// surface and no owner for it. These are never offered as selections.
  final List<ClientSection> unavailable;

  /// The mounted destination an unavailable selection recovers to.
  ///
  /// [MountedDestinationSet.recoveryFor] answers the route; it is null only
  /// when this client mounts nothing at all.
  final ClientSection? recoveryDestination;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationProjection &&
          other.destination == destination &&
          samePresentationList(other.destinations, destinations) &&
          samePresentationList(other.unavailable, unavailable) &&
          other.recoveryDestination == recoveryDestination;

  @override
  int get hashCode => Object.hash(
    destination,
    Object.hashAll(destinations),
    Object.hashAll(unavailable),
    recoveryDestination,
  );
}

final class StatusProjection {
  const StatusProjection({
    required this.messageChinese,
    required this.messageEnglish,
    required this.caption,
    required this.errorCode,
  });

  final String messageChinese;
  final String messageEnglish;
  final String caption;
  final String errorCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatusProjection &&
          other.messageChinese == messageChinese &&
          other.messageEnglish == messageEnglish &&
          other.caption == caption &&
          other.errorCode == errorCode;

  @override
  int get hashCode =>
      Object.hash(messageChinese, messageEnglish, caption, errorCode);
}
