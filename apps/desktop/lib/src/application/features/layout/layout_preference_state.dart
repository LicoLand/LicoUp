import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';

/// Application-owned layout preference transaction state. Viewport and
/// surface are intentionally absent; those are Presentation Environment.
final class LayoutPreferenceState {
  const LayoutPreferenceState({
    required this.committedId,
    required this.effectiveId,
    required this.status,
    required this.operationEpoch,
    this.errorCode,
    this.effectiveStyleId,
  });

  final LayoutProfileId committedId;
  final LayoutProfileId effectiveId;
  final LayoutSelectionStatus status;
  final int operationEpoch;
  final LayoutSelectionErrorCode? errorCode;

  /// The style [effectiveId] renders with: the stored choice when that
  /// profile declares it, else the profile's declared default, else null.
  final LayoutStyleId? effectiveStyleId;
}
