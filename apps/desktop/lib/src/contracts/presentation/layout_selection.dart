import 'layout_environment.dart';
import 'layout_profile.dart';
import 'layout_variant.dart';

enum LayoutSelectionStatus { loading, stable, previewing, committing, error }

enum LayoutSelectionErrorCode {
  invalidProfile,
  unavailableProfile,
  invalidStoredPreference,
  persistenceFailed,
  previewExpired,
}

final class LayoutSelectionState {
  const LayoutSelectionState({
    required this.committedId,
    required this.effectiveId,
    required this.status,
    required this.surface,
    required this.viewport,
    required this.operationEpoch,
    this.previewId,
    this.errorCode,
  }) : assert(operationEpoch >= 0);

  final LayoutProfileId committedId;
  final LayoutProfileId effectiveId;
  final LayoutProfileId? previewId;
  final LayoutSelectionStatus status;
  final LayoutRuntimeSurface surface;
  final LayoutViewportClass viewport;
  final int operationEpoch;
  final LayoutSelectionErrorCode? errorCode;

  LayoutVariantKey get effectiveVariantKey => LayoutVariantKey(
    profileId: effectiveId,
    surface: surface,
    viewport: viewport,
  );
}
