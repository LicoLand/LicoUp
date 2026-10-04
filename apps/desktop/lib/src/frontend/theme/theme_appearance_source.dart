import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';

/// Which appearance the theme renders for one resource kind, and on whose
/// answer.
///
/// This is the render boundary's value. A theme reads it instead of the
/// application owner, and it carries exactly the two facts a renderer may act
/// on: what the user asked for, and what the package owner reported. It has no
/// constructor that invents either one, so a theme cannot render an
/// uninstalled resource as if it were serving, and cannot report a fallback
/// reason nobody gave.
final class ThemeAppearanceSource {
  const ThemeAppearanceSource({
    required this.kindId,
    required this.serving,
    this.requestedResourceId,
    this.servedResourceId,
    this.servedPackageGeneration,
    this.fallbackReasonCode,
  });

  /// Reads the render decision from the resolved state of one kind.
  factory ThemeAppearanceSource.fromResourceState(
    PresentationResourceState state,
  ) => ThemeAppearanceSource(
    kindId: state.kind.id,
    serving: state.serving,
    requestedResourceId: state.requested?.resourceId,
    servedResourceId: state.servedResourceId,
    servedPackageGeneration: state.servedPackageGeneration,
    fallbackReasonCode: state.fallbackReasonCode,
  );

  /// The resource kind this decision belongs to, in the host's own spelling.
  final String kindId;

  final PresentationResourceServing serving;

  /// The resource the user asked for, or `null` when the declared default was
  /// asked for.
  final String? requestedResourceId;

  /// The resource the package owner reports serving, or `null` when the
  /// client's own declared default renders.
  final String? servedResourceId;

  final int? servedPackageGeneration;

  /// The package owner's recorded reason the request is not served, or `null`
  /// when it named none.
  final String? fallbackReasonCode;

  /// Whether the theme renders the resource the user asked for.
  bool get rendersRequestedResource =>
      requestedResourceId != null && servedResourceId == requestedResourceId;

  /// Whether the client's own declared appearance renders for this kind.
  bool get rendersDeclaredAppearance => servedResourceId == null;

  /// Whether the package owner answered for this kind at all.
  ///
  /// A request with no answer renders the declared appearance while the
  /// question is open; a surface shows "not reported yet" rather than claiming
  /// the resource is served or that it failed.
  bool get isReported => serving != PresentationResourceServing.unreported;

  /// Whether the request is recorded and the answer is a fallback.
  bool get isFallback => serving == PresentationResourceServing.fallback;

  /// Whether a resource renders that no stored request names.
  bool get isUnrequested => serving == PresentationResourceServing.unrequested;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ThemeAppearanceSource &&
          other.kindId == kindId &&
          other.serving == serving &&
          other.requestedResourceId == requestedResourceId &&
          other.servedResourceId == servedResourceId &&
          other.servedPackageGeneration == servedPackageGeneration &&
          other.fallbackReasonCode == fallbackReasonCode;

  @override
  int get hashCode => Object.hash(
    kindId,
    serving,
    requestedResourceId,
    servedResourceId,
    servedPackageGeneration,
    fallbackReasonCode,
  );

  @override
  String toString() =>
      'ThemeAppearanceSource($kindId, ${serving.name}'
      '${fallbackReasonCode == null ? '' : ', $fallbackReasonCode'})';
}
