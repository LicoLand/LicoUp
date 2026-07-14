/// Stores semantic focus identity, never widget instances or global keys.
final class LayoutFocusCoordinator {
  String? _capturedTarget;

  String? get capturedTarget => _capturedTarget;

  void capture(String? semanticTarget) {
    if (semanticTarget == null) {
      _capturedTarget = null;
      return;
    }
    _validateTarget(semanticTarget);
    _capturedTarget = semanticTarget;
  }

  String resolve({
    required Set<String> availableTargets,
    required String primaryTarget,
  }) {
    _validateTarget(primaryTarget);
    if (!availableTargets.contains(primaryTarget)) {
      throw const FormatException('layout_focus_primary_missing');
    }
    for (final target in availableTargets) {
      _validateTarget(target);
    }
    final captured = _capturedTarget;
    return captured != null && availableTargets.contains(captured)
        ? captured
        : primaryTarget;
  }

  void clear() => _capturedTarget = null;

  static void _validateTarget(String target) {
    if (!_targetPattern.hasMatch(target)) {
      throw const FormatException('layout_focus_target_invalid');
    }
  }

  static final RegExp _targetPattern = RegExp(r'^[a-z]+(?:-[a-z]+)*$');
}
