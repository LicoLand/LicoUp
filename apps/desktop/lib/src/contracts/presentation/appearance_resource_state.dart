/// The appearance resource facts one client surface may read.
///
/// These are the host package contract's kind vocabulary, the user's stored
/// request, and the package owner's report, plus the one resolution between
/// them. The file is a pure value contract: it has no runtime owner, no
/// repository and no asynchronous member, so a renderer can read exactly the
/// facts it is allowed to act on without reaching an implementation layer.
library;

/// The resource kinds the host package contract publishes.
///
/// The identifiers are the host contract's own spelling
/// (`licoup_extension_contracts::manifest::ResourceKind::as_str`). A second
/// spelling here would be a second vocabulary for one published fact.
enum PresentationResourceKind {
  theme('theme'),
  layout('layout'),
  style('style'),
  font('font'),
  language('language'),
  composition('composition');

  const PresentationResourceKind(this.id);

  final String id;

  static PresentationResourceKind? parse(String value) {
    for (final kind in values) {
      if (kind.id == value) {
        return kind;
      }
    }
    return null;
  }
}

/// One resource the user asked this client to serve.
///
/// This is the request, not the result. [resourceId] is the identity the user
/// chose; [packageId] and [packageGeneration] are what the surface reported
/// when the choice was made. Whether the resource is *served* is decided by the
/// package owner and never stored here, so a package that is disabled,
/// uninstalled or replaced cannot rewrite what the user asked for.
///
/// The host contract owns identity validity (`is_namespaced`); this value only
/// keeps one document from carrying an unbounded or line-broken identity, so a
/// hand-edited file cannot smuggle a second document into this one.
final class PresentationResourceSelection {
  factory PresentationResourceSelection({
    required String resourceId,
    String packageId = '',
    int? packageGeneration,
  }) {
    final id = resourceId.trim();
    if (!_validStoredIdentity(id)) {
      throw const FormatException('presentation_resource_id_invalid');
    }
    final package = packageId.trim();
    if (!_validStoredIdentity(package, allowEmpty: true)) {
      throw const FormatException('presentation_resource_package_invalid');
    }
    if (packageGeneration != null && packageGeneration < 0) {
      throw const FormatException('presentation_resource_generation_invalid');
    }
    return PresentationResourceSelection._(
      resourceId: id,
      packageId: package,
      packageGeneration: packageGeneration,
    );
  }

  /// Reads one stored request strictly.
  ///
  /// A stored entry is either a request this build can carry or a document it
  /// refuses; it is never reinterpreted into a different request.
  factory PresentationResourceSelection.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('presentation_resource_selection_invalid');
    }
    final resourceId = value['resourceId'];
    if (resourceId is! String) {
      throw const FormatException('presentation_resource_id_invalid');
    }
    final packageId = value['packageId'];
    if (packageId != null && packageId is! String) {
      throw const FormatException('presentation_resource_package_invalid');
    }
    final generation = value['packageGeneration'];
    if (generation != null && generation is! int) {
      throw const FormatException('presentation_resource_generation_invalid');
    }
    return PresentationResourceSelection(
      resourceId: resourceId,
      packageId: packageId is String ? packageId : '',
      packageGeneration: generation is int ? generation : null,
    );
  }

  const PresentationResourceSelection._({
    required this.resourceId,
    required this.packageId,
    required this.packageGeneration,
  });

  /// The longest identity this store accepts. The host contract's own bound is
  /// 160 bytes (`MAX_NAMESPACED_NAME_BYTES`).
  static const int maxIdentityLength = 160;

  /// The identity of the resource the user asked for.
  final String resourceId;

  /// The package that supplied the resource when the choice was made, or an
  /// empty string when the choice named no package.
  final String packageId;

  /// The package generation the choice was made against, when one was
  /// reported. A generation is an observation, never the identity: a
  /// reinstall publishes the same identity at a new generation and the user's
  /// request still applies.
  final int? packageGeneration;

  Map<String, Object> toJson() => {
    'resourceId': resourceId,
    if (packageId.isNotEmpty) 'packageId': packageId,
    'packageGeneration': ?packageGeneration,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationResourceSelection &&
          other.resourceId == resourceId &&
          other.packageId == packageId &&
          other.packageGeneration == packageGeneration;

  @override
  int get hashCode => Object.hash(resourceId, packageId, packageGeneration);

  @override
  String toString() =>
      'PresentationResourceSelection($resourceId'
      '${packageId.isEmpty ? '' : ' from $packageId'}'
      '${packageGeneration == null ? '' : ' generation $packageGeneration'})';
}

/// Why the resource the user asked for is not the one being served.
///
/// The vocabulary is the host lifecycle's own (`FallbackReason`): a surface
/// reports the change that was recorded, and never derives a reason from a
/// missing resource.
enum PresentationResourceFallbackReason {
  disabled('disabled'),
  uninstalled('uninstalled'),
  replaced('replaced');

  const PresentationResourceFallbackReason(this.id);

  final String id;

  static PresentationResourceFallbackReason? parse(String value) {
    for (final reason in values) {
      if (reason.id == value) {
        return reason;
      }
    }
    return null;
  }
}

/// What the package owner reports for one resource kind right now.
///
/// A report is the package owner's answer, carried here unchanged. An absent
/// report for a kind is not "the declared default serves"; it is the absence of
/// an answer, and [PresentationResourceServing.unreported] is how a surface
/// says so.
final class PresentationResourceReport {
  const PresentationResourceReport({
    this.servedResourceId,
    this.packageGeneration,
    this.fallbackReason,
  });

  /// The resource the package owner serves, or `null` when the client's own
  /// declared default serves.
  final String? servedResourceId;

  /// The generation of the package serving [servedResourceId], when reported.
  final int? packageGeneration;

  /// The change the package owner recorded, when it reported one. A report that
  /// answers "not served" without naming the change leaves this `null`; a
  /// surface must not guess the reason.
  final PresentationResourceFallbackReason? fallbackReason;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationResourceReport &&
          other.servedResourceId == servedResourceId &&
          other.packageGeneration == packageGeneration &&
          other.fallbackReason == fallbackReason;

  @override
  int get hashCode =>
      Object.hash(servedResourceId, packageGeneration, fallbackReason);
}

/// What one kind is doing, as a pure function of the stored request and the
/// package owner's report.
enum PresentationResourceServing {
  /// No request is recorded and no resource is reported serving: the client's
  /// own declared appearance renders.
  declaredDefault,

  /// The reported resource is the one the user asked for.
  requested,

  /// The request is recorded and the report says it is not the resource being
  /// served. The request survives; what is served does not.
  fallback,

  /// The request is recorded and no report has answered for this kind yet. The
  /// request is neither confirmed nor failed.
  unreported,

  /// A resource is reported serving and no stored request names it, so nothing
  /// this client recorded explains the choice.
  unrequested,
}

/// The truthful state of one resource kind.
///
/// Every field is either the stored request, the reported answer, or absent.
/// The value has one resolver ([PresentationResourceState.resolve]) so the
/// owner, a projection and a test cannot each derive a different answer from
/// the same two facts.
final class PresentationResourceState {
  const PresentationResourceState({
    required this.kind,
    required this.serving,
    this.requested,
    this.servedResourceId,
    this.servedPackageGeneration,
    this.fallbackReason,
  });

  /// Resolves one kind from the two owners' facts.
  static PresentationResourceState resolve({
    required PresentationResourceKind kind,
    required PresentationResourceSelection? request,
    required PresentationResourceReport? report,
  }) {
    if (request == null) {
      final served = report?.servedResourceId;
      return PresentationResourceState(
        kind: kind,
        serving: served == null
            ? PresentationResourceServing.declaredDefault
            : PresentationResourceServing.unrequested,
        servedResourceId: served,
        servedPackageGeneration: report?.packageGeneration,
      );
    }
    if (report == null) {
      return PresentationResourceState(
        kind: kind,
        serving: PresentationResourceServing.unreported,
        requested: request,
      );
    }
    if (report.servedResourceId == request.resourceId) {
      return PresentationResourceState(
        kind: kind,
        serving: PresentationResourceServing.requested,
        requested: request,
        servedResourceId: report.servedResourceId,
        servedPackageGeneration: report.packageGeneration,
      );
    }
    return PresentationResourceState(
      kind: kind,
      serving: PresentationResourceServing.fallback,
      requested: request,
      servedResourceId: report.servedResourceId,
      servedPackageGeneration: report.packageGeneration,
      fallbackReason: report.fallbackReason,
    );
  }

  final PresentationResourceKind kind;

  final PresentationResourceServing serving;

  /// What the user asked for, or `null` when the declared default was asked
  /// for. A fallback never clears this.
  final PresentationResourceSelection? requested;

  /// The resource being served, or `null` when the client's own declared
  /// default is rendering.
  final String? servedResourceId;

  /// The generation of the package serving [servedResourceId], when reported.
  final int? servedPackageGeneration;

  /// The recorded reason the request is not served, when the package owner
  /// named one.
  final PresentationResourceFallbackReason? fallbackReason;

  /// Whether the resource the user asked for is the one being served.
  bool get rendersRequestedResource =>
      requested != null && servedResourceId == requested!.resourceId;

  /// Whether the client's own declared appearance renders for this kind.
  bool get rendersDeclaredAppearance => servedResourceId == null;

  /// Whether the package owner answered for this kind at all.
  bool get isReported => serving != PresentationResourceServing.unreported;

  /// Whether the request is recorded and the answer is a fallback.
  bool get isFallback => serving == PresentationResourceServing.fallback;

  /// A stable code for a surface that reports why the request is not rendering,
  /// or `null` when no reason was reported.
  String? get fallbackReasonCode => fallbackReason?.id;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresentationResourceState &&
          other.kind == kind &&
          other.serving == serving &&
          other.requested == requested &&
          other.servedResourceId == servedResourceId &&
          other.servedPackageGeneration == servedPackageGeneration &&
          other.fallbackReason == fallbackReason;

  @override
  int get hashCode => Object.hash(
    kind,
    serving,
    requested,
    servedResourceId,
    servedPackageGeneration,
    fallbackReason,
  );

  @override
  String toString() =>
      'PresentationResourceState(${kind.id}, ${serving.name}'
      '${fallbackReason == null ? '' : ', ${fallbackReason!.id}'})';
}

final _storedIdentityPattern = RegExp(r'^[^\s\x00-\x1f\x7f]+$');

bool _validStoredIdentity(String value, {bool allowEmpty = false}) {
  if (value.isEmpty) {
    return allowEmpty;
  }
  return value.length <= PresentationResourceSelection.maxIdentityLength &&
      _storedIdentityPattern.hasMatch(value);
}

final _resourceKindKeyPattern = RegExp(r'^[a-z][a-z0-9-]{0,63}$');


/// Reads a stored `resourceSelections` map strictly.
///
/// A key this build does not know keeps the identity it was written with, so a
/// newer client's request survives an older client's write. A value this build
/// cannot read refuses the document instead of being dropped or reinterpreted:
/// an unreadable request is not a different request.
Map<String, PresentationResourceSelection> readPresentationResourceSelections(
  Object? value,
) {
  if (value == null) {
    return const {};
  }
  if (value is! Map) {
    throw const FormatException('presentation_resource_selections_invalid');
  }
  final selections = <String, PresentationResourceSelection>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String || !_resourceKindKeyPattern.hasMatch(key)) {
      throw const FormatException('presentation_resource_kind_invalid');
    }
    selections[key] = PresentationResourceSelection.fromJson(entry.value);
  }
  return Map<String, PresentationResourceSelection>.unmodifiable(selections);
}
