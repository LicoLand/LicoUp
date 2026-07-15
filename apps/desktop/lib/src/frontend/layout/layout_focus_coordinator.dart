import 'dart:collection';

import 'package:flutter/widgets.dart';

/// Stable semantic focus identities shared by business surfaces and layouts.
abstract final class LayoutFocusTargets {
  static const primaryLandmark = 'primary-landmark';
  static const composerField = 'composer-field';
}

/// Coordinates semantic focus across replacement of the active layout tree.
///
/// Nodes are registered only while mounted. Before a bundle replacement the
/// host captures the most specific active semantic target; after the new tree
/// mounts it requests the equivalent target, or the real primary landmark.
final class LayoutFocusCoordinator {
  final Map<String, LinkedHashSet<FocusNode>> _nodesByTarget = {};
  String? _capturedTarget;

  String? get capturedTarget => _capturedTarget;

  Set<String> get registeredTargets => Set.unmodifiable(
    _nodesByTarget.entries
        .where((entry) => entry.value.isNotEmpty)
        .map((entry) => entry.key),
  );

  void register(String semanticTarget, FocusNode node) {
    _validateTarget(semanticTarget);
    (_nodesByTarget[semanticTarget] ??= LinkedHashSet<FocusNode>.identity())
        .add(node);
  }

  void unregister(String semanticTarget, FocusNode node) {
    final nodes = _nodesByTarget[semanticTarget];
    if (nodes == null) {
      return;
    }
    nodes.remove(node);
    if (nodes.isEmpty) {
      _nodesByTarget.remove(semanticTarget);
    }
  }

  /// Captures a registered target from the currently mounted active tree.
  String? captureActiveTarget() {
    for (final entry in _nodesByTarget.entries) {
      if (entry.value.any((node) => node.hasPrimaryFocus)) {
        _capturedTarget = entry.key;
        return _capturedTarget;
      }
    }
    for (final entry in _nodesByTarget.entries) {
      if (entry.value.any((node) => node.hasFocus)) {
        _capturedTarget = entry.key;
        return _capturedTarget;
      }
    }
    _capturedTarget = null;
    return null;
  }

  /// The semantic target profiles may use for stable keys during replacement.
  String replacementTarget({required String primaryTarget}) {
    _validateTarget(primaryTarget);
    return _capturedTarget ?? primaryTarget;
  }

  /// Transfers a semantic target captured by a coordinator being replaced.
  void adoptCapturedTarget(String? semanticTarget) {
    if (semanticTarget != null) {
      _validateTarget(semanticTarget);
    }
    _capturedTarget = semanticTarget;
  }

  /// Requests focus in the newly mounted tree, falling back deterministically.
  bool restore({required String primaryTarget}) {
    _validateTarget(primaryTarget);
    final captured = _capturedTarget;
    if (captured != null && _requestFirstAvailable(captured)) {
      return true;
    }
    return _requestFirstAvailable(primaryTarget);
  }

  bool _requestFirstAvailable(String semanticTarget) {
    final nodes = _nodesByTarget[semanticTarget];
    if (nodes == null) {
      return false;
    }
    for (final node in nodes) {
      if (node.canRequestFocus) {
        node.requestFocus();
        return true;
      }
    }
    return false;
  }

  void clear() => _capturedTarget = null;

  static void _validateTarget(String target) {
    if (!_targetPattern.hasMatch(target)) {
      throw const FormatException('layout_focus_target_invalid');
    }
  }

  static final RegExp _targetPattern = RegExp(r'^[a-z]+(?:-[a-z]+)*$');
}

/// Makes the active host's bounded focus registry available to descendants.
final class LayoutFocusScope extends InheritedWidget {
  const LayoutFocusScope({
    super.key,
    required this.coordinator,
    required super.child,
  });

  final LayoutFocusCoordinator coordinator;

  static LayoutFocusCoordinator? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LayoutFocusScope>()
      ?.coordinator;

  @override
  bool updateShouldNotify(LayoutFocusScope oldWidget) =>
      !identical(oldWidget.coordinator, coordinator);
}

/// Registers an owned focus node for a semantic target without visual output.
final class LayoutFocusTarget extends StatefulWidget {
  const LayoutFocusTarget({
    super.key,
    required this.semanticTarget,
    required this.child,
    this.canRequestFocus = true,
    this.skipTraversal = true,
  });

  final String semanticTarget;
  final Widget child;
  final bool canRequestFocus;
  final bool skipTraversal;

  @override
  State<LayoutFocusTarget> createState() => _LayoutFocusTargetState();
}

final class _LayoutFocusTargetState extends State<LayoutFocusTarget> {
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'layout-semantic-focus',
  );
  LayoutFocusCoordinator? _coordinator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(LayoutFocusScope.maybeOf(context));
  }

  @override
  void didUpdateWidget(LayoutFocusTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.semanticTarget != widget.semanticTarget) {
      _coordinator?.unregister(oldWidget.semanticTarget, _focusNode);
      _coordinator?.register(widget.semanticTarget, _focusNode);
    }
  }

  void _bind(LayoutFocusCoordinator? next) {
    if (identical(next, _coordinator)) {
      return;
    }
    _coordinator?.unregister(widget.semanticTarget, _focusNode);
    _coordinator = next;
    _coordinator?.register(widget.semanticTarget, _focusNode);
  }

  @override
  void dispose() {
    _coordinator?.unregister(widget.semanticTarget, _focusNode);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focusNode,
    canRequestFocus: widget.canRequestFocus,
    skipTraversal: widget.skipTraversal,
    child: widget.child,
  );
}

/// Registers an existing control-owned node, such as a composer field.
final class LayoutFocusNodeRegistration extends StatefulWidget {
  const LayoutFocusNodeRegistration({
    super.key,
    required this.semanticTarget,
    required this.focusNode,
    required this.child,
  });

  final String semanticTarget;
  final FocusNode focusNode;
  final Widget child;

  @override
  State<LayoutFocusNodeRegistration> createState() =>
      _LayoutFocusNodeRegistrationState();
}

final class _LayoutFocusNodeRegistrationState
    extends State<LayoutFocusNodeRegistration> {
  LayoutFocusCoordinator? _coordinator;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(LayoutFocusScope.maybeOf(context));
  }

  @override
  void didUpdateWidget(LayoutFocusNodeRegistration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.semanticTarget != widget.semanticTarget ||
        !identical(oldWidget.focusNode, widget.focusNode)) {
      _coordinator?.unregister(oldWidget.semanticTarget, oldWidget.focusNode);
      _coordinator?.register(widget.semanticTarget, widget.focusNode);
    }
  }

  void _bind(LayoutFocusCoordinator? next) {
    if (identical(next, _coordinator)) {
      return;
    }
    _coordinator?.unregister(widget.semanticTarget, widget.focusNode);
    _coordinator = next;
    _coordinator?.register(widget.semanticTarget, widget.focusNode);
  }

  @override
  void dispose() {
    _coordinator?.unregister(widget.semanticTarget, widget.focusNode);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
