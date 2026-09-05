import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';

/// Application-owned layout preference transaction state. Viewport and
/// surface are intentionally absent; those are Presentation Environment.
final class LayoutPreferenceState {
  const LayoutPreferenceState({
    required this.committedId,
    required this.effectiveId,
    required this.status,
    required this.operationEpoch,
    this.errorCode,
  });

  final LayoutProfileId committedId;
  final LayoutProfileId effectiveId;
  final LayoutSelectionStatus status;
  final int operationEpoch;
  final LayoutSelectionErrorCode? errorCode;
}
