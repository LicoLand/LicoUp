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
  factory LayoutSelectionState({
    required LayoutProfileId committedId,
    required LayoutProfileId effectiveId,
    required LayoutSelectionStatus status,
    required LayoutRuntimeSurface surface,
    required LayoutViewportClass viewport,
    required int operationEpoch,
    LayoutProfileId? previewId,
    LayoutSelectionErrorCode? errorCode,
  }) {
    if (operationEpoch < 0) {
      throw const FormatException('layout_selection_epoch_invalid');
    }
    if (!LayoutViewportPolicy.supports(surface, viewport)) {
      throw const FormatException('layout_selection_viewport_invalid');
    }
    final hasCandidate = previewId != null;
    final candidateStatus =
        status == LayoutSelectionStatus.previewing ||
        status == LayoutSelectionStatus.committing;
    if (candidateStatus != hasCandidate ||
        (hasCandidate && effectiveId != previewId) ||
        (!hasCandidate && effectiveId != committedId)) {
      throw const FormatException('layout_selection_candidate_invalid');
    }
    if ((status == LayoutSelectionStatus.error) != (errorCode != null)) {
      throw const FormatException('layout_selection_error_state_invalid');
    }
    return LayoutSelectionState._(
      committedId: committedId,
      effectiveId: effectiveId,
      status: status,
      surface: surface,
      viewport: viewport,
      operationEpoch: operationEpoch,
      previewId: previewId,
      errorCode: errorCode,
    );
  }

  const LayoutSelectionState._({
    required this.committedId,
    required this.effectiveId,
    required this.status,
    required this.surface,
    required this.viewport,
    required this.operationEpoch,
    required this.previewId,
    required this.errorCode,
  });

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutSelectionState &&
          other.committedId == committedId &&
          other.effectiveId == effectiveId &&
          other.previewId == previewId &&
          other.status == status &&
          other.surface == surface &&
          other.viewport == viewport &&
          other.operationEpoch == operationEpoch &&
          other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(
    committedId,
    effectiveId,
    previewId,
    status,
    surface,
    viewport,
    operationEpoch,
    errorCode,
  );
}
