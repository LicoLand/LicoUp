import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class NavigationProjection {
  NavigationProjection({
    required this.destination,
    required Iterable<ClientSection> destinations,
  }) : destinations = immutablePresentationList(destinations);

  final ClientSection destination;
  final List<ClientSection> destinations;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationProjection &&
          other.destination == destination &&
          samePresentationList(other.destinations, destinations);

  @override
  int get hashCode => Object.hash(destination, Object.hashAll(destinations));
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
