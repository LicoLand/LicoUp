import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/appearance_resource_state.dart';
import 'package:licoup/src/contracts/presentation/presentation_plan_appearance.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';

/// Owns appearance preference and catalog state independently of locale and
/// functional status.
///
/// Two facts about a resource kind live here and nowhere else in the client:
///
/// - **the request** — which installed theme, layout, style, font, language or
///   composition the user asked this client to serve. It is the durable
///   preference: disabling, uninstalling or replacing a package never rewrites
///   it, so switching the package back on restores the user's choice.
/// - **the report** — what the package owner answers for that kind right now.
///   A report is adopted, never derived: an absent answer stays absent.
///
/// The single truthful state of a kind is their pure resolution
/// ([PresentationResourceState.resolve]); this owner does not keep a second
/// copy of either fact, and it never turns "no answer" into a served resource
/// or into a fallback.
///
/// What the client actually renders is a third adopted fact kept here: the
/// projection a published native mount plan resolved ([planAppearance]). It is
/// adopted through the host registry exactly like a report — never derived from
/// a plan document in this owner — and `null` means no plan is published, so
/// the client renders its built-in appearance.
final class AppearancePreferenceOwner extends ApplicationStateOwner {
  AppearancePreferenceOwner({
    String presetId = AppearancePresetIds.defaultSystem,
    ReduceMotionPreference reduceMotion = ReduceMotionPreference.system,
    List<AppearancePresetConfig> presets = builtInAppearancePresetConfigs,
    Map<String, PresentationResourceSelection> resourceSelections = const {},
  }) : _presetId = presetId,
       _reduceMotion = reduceMotion,
       _presets = List.unmodifiable(presets),
       _resourceSelections =
           Map<String, PresentationResourceSelection>.unmodifiable(
             Map<String, PresentationResourceSelection>.of(resourceSelections),
           );

  String _presetId;
  ReduceMotionPreference _reduceMotion;
  String _loadingEffectId = 'spinner';
  String get loadingEffectId => _loadingEffectId;
  String _fontPreference = 'system';
  List<AppearancePresetConfig> _presets;
  String _directoryPath = '';
  List<String> _loadErrors = const [];
  Map<PresentationResourceKind, PresentationResourceReport> _resourceReports =
      const {};
  Map<String, PresentationResourceSelection> _resourceSelections;
  PresentationPlanAppearance? _planAppearance;
  List<MountedContribution> _planContributions = const [];

  String get presetId => _presetId;
  ReduceMotionPreference get reduceMotion => _reduceMotion;
  String get fontPreference => _fontPreference;
  List<AppearancePresetConfig> get presets => _presets;
  List<AppearancePresetConfig> get selectablePresets => _presets
      .where(
        (config) =>
            !AppearancePresetIds.resolutionOnly.contains(config.id) &&
            config.mode != AppearancePresetMode.system,
      )
      .toList(growable: false);
  String get directoryPath => _directoryPath;
  List<String> get loadErrors => _loadErrors;

  /// The resource the user asked this client to serve, per resource kind id.
  ///
  /// A kind with no entry records no request: the client's own declared default
  /// serves it. The map is the owner's request half; it is never written from a
  /// report.
  Map<String, PresentationResourceSelection> get resourceSelections =>
      _resourceSelections;

  /// The stored request for one kind, when the user made one.
  PresentationResourceSelection? requestedResource(
    PresentationResourceKind kind,
  ) => _resourceSelections[kind.id];

  /// The truthful state of one kind: the request resolved against the report.
  PresentationResourceState resourceState(PresentationResourceKind kind) =>
      PresentationResourceState.resolve(
        kind: kind,
        request: requestedResource(kind),
        report: _resourceReports[kind],
      );

  /// Every kind this build serves, in the published kind order.
  List<PresentationResourceState> get resourceStates => [
    for (final kind in PresentationResourceKind.values) resourceState(kind),
  ];

  /// Records the user's request for one kind, or clears it when [selection] is
  /// `null` (the user asked for the client's own declared default).
  ///
  /// The request is stored exactly as chosen. It is not matched against the
  /// published resources here: an answer about availability belongs to the
  /// package owner, and refusing or rewriting the choice in this owner is how a
  /// temporary absence would destroy a preference the user can get back.
  bool requestResource(
    PresentationResourceKind kind,
    PresentationResourceSelection? selection, {
    ApplicationCause? cause,
  }) {
    final next = Map<String, PresentationResourceSelection>.of(
      _resourceSelections,
    );
    if (selection == null) {
      next.remove(kind.id);
    } else {
      next[kind.id] = selection;
    }
    if (_sameSelections(next, _resourceSelections)) return false;
    _resourceSelections =
        Map<String, PresentationResourceSelection>.unmodifiable(next);
    publishChange(cause);
    return true;
  }

  /// Adopts the durable record read at startup.
  ///
  /// This is how a restart reaches the surface: the stored requests are the
  /// user's, unchanged, including a kind this build does not serve, which stays
  /// recorded for the build that does. No availability answer is adopted with
  /// them; the package owner reports that separately.
  bool adoptResourceSelections(
    Map<String, PresentationResourceSelection> selections, {
    ApplicationCause? cause,
  }) {
    if (_sameSelections(selections, _resourceSelections)) return false;
    _resourceSelections =
        Map<String, PresentationResourceSelection>.unmodifiable(
          Map<String, PresentationResourceSelection>.of(selections),
        );
    publishChange(cause);
    return true;
  }

  /// Adopts what the package owner reports for each kind.
  ///
  /// A kind the map does not name stays unanswered, which is the state a
  /// surface reports as unreported rather than as a served resource or a
  /// fallback. No report changes a request.
  bool replaceResourceReports(
    Map<PresentationResourceKind, PresentationResourceReport> reports, {
    ApplicationCause? cause,
  }) {
    if (_sameReports(reports, _resourceReports)) return false;
    _resourceReports =
        Map<PresentationResourceKind, PresentationResourceReport>.unmodifiable(
          Map<PresentationResourceKind, PresentationResourceReport>.of(reports),
        );
    publishChange(cause);
    return true;
  }

  /// The appearance the native mount plan projects, or `null` while no plan is
  /// published and the client renders its built-in appearance.
  PresentationPlanAppearance? get planAppearance => _planAppearance;

  /// The contributions the published plan mounted, in plan order.
  ///
  /// These are what a package contributes to this client's own interface, and
  /// they are adopted, never derived: an owner that invented one would render
  /// something no native host decided to mount.
  List<MountedContribution> get planContributions => _planContributions;

  /// Adopts the contributions one mounted plan revision carries.
  ///
  /// The caller mounted the revision through the host registry, so a refused
  /// contribution is already absent here; passing an empty list withdraws them.
  bool replacePlanContributions(
    Iterable<MountedContribution> contributions, {
    ApplicationCause? cause,
  }) {
    final next = List<MountedContribution>.unmodifiable(contributions);
    if (_sameContributions(next, _planContributions)) return false;
    _planContributions = next;
    publishChange(cause);
    return true;
  }

  /// Adopts the appearance a published native mount plan resolved.
  ///
  /// The caller resolved it through the host registry, so this owner stores the
  /// projection instead of interpreting a plan document. Passing `null`
  /// withdraws it and returns rendering to the built-in appearance.
  bool replacePlanAppearance(
    PresentationPlanAppearance? appearance, {
    ApplicationCause? cause,
  }) {
    if (_planAppearance == appearance) return false;
    _planAppearance = appearance;
    publishChange(cause);
    return true;
  }

  bool replacePreset(String value, {ApplicationCause? cause}) {
    final normalized = hasAppearancePresetConfig(value, _presets)
        ? value
        : AppearancePresetIds.defaultSystem;
    if (_presetId == normalized) return false;
    _presetId = normalized;
    publishChange(cause);
    return true;
  }

  bool replaceFontPreference(String value, {ApplicationCause? cause}) {
    final normalized = value.trim().isEmpty ? 'system' : value.trim();
    if (_fontPreference == normalized) return false;
    _fontPreference = normalized;
    publishChange(cause);
    return true;
  }

  bool replaceReduceMotion(
    ReduceMotionPreference value, {
    ApplicationCause? cause,
  }) {
    if (_reduceMotion == value) return false;
    _reduceMotion = value;
    publishChange(cause);
    return true;
  }

  bool replaceLoadingEffect(String id, {ApplicationCause? cause}) {
    if (_loadingEffectId == id) return false;
    _loadingEffectId = id;
    publishChange(cause);
    return true;
  }

  bool applyCatalog({
    required List<AppearancePresetConfig> configs,
    required String directoryPath,
    Iterable<String> errorCodes = const [],
  }) {
    _presets = List.unmodifiable(mergeAppearancePresetConfigs(configs));
    _directoryPath = directoryPath;
    _loadErrors = List.unmodifiable(
      errorCodes.map(_safeCode).where((code) => code.isNotEmpty),
    );
    final fellBack = !hasAppearancePresetConfig(_presetId, _presets);
    if (fellBack) _presetId = AppearancePresetIds.defaultSystem;
    publishChange();
    return fellBack;
  }

  static final RegExp _stableCode = RegExp(
    r'^[a-z][a-z0-9]*(?:[._:-][a-z0-9]+)*$',
  );

  static String _safeCode(String value) {
    final normalized = value.trim().toLowerCase();
    return _stableCode.hasMatch(normalized) ? normalized : '';
  }
}

bool _sameSelections(
  Map<String, PresentationResourceSelection> left,
  Map<String, PresentationResourceSelection> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

bool _sameReports(
  Map<PresentationResourceKind, PresentationResourceReport> left,
  Map<PresentationResourceKind, PresentationResourceReport> right,
) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

/// Whether two mounted lists are the same revision's contributions.
///
/// Order is part of the comparison: a plan publishes its contributions in a
/// fixed order, so the same set in a different order is a different rendering.
bool _sameContributions(
  List<MountedContribution> left,
  List<MountedContribution> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
