import 'package:flutter_client/src/application/features/layout/layout_catalog.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';

sealed class LayoutPresentationStateValue {
  const LayoutPresentationStateValue();
}

final class LayoutScrollState extends LayoutPresentationStateValue {
  factory LayoutScrollState(double offset) {
    if (!offset.isFinite || offset < 0) {
      throw const FormatException('layout_state_scroll_invalid');
    }
    return LayoutScrollState._(offset);
  }

  const LayoutScrollState._(this.offset);

  final double offset;
}

final class LayoutPaneExtentState extends LayoutPresentationStateValue {
  factory LayoutPaneExtentState(double extent) {
    if (!extent.isFinite || extent < 0) {
      throw const FormatException('layout_state_pane_extent_invalid');
    }
    return LayoutPaneExtentState._(extent);
  }

  const LayoutPaneExtentState._(this.extent);

  final double extent;
}

final class LayoutExpansionState extends LayoutPresentationStateValue {
  const LayoutExpansionState(this.expanded);

  final bool expanded;
}

final class LayoutTabState extends LayoutPresentationStateValue {
  factory LayoutTabState(int index) {
    if (index < 0) {
      throw const FormatException('layout_state_tab_invalid');
    }
    return LayoutTabState._(index);
  }

  const LayoutTabState._(this.index);

  final int index;
}

final class LayoutFocusState extends LayoutPresentationStateValue {
  factory LayoutFocusState(String semanticTarget) {
    if (!_semanticTargetPattern.hasMatch(semanticTarget)) {
      throw const FormatException('layout_state_focus_target_invalid');
    }
    return LayoutFocusState._(semanticTarget);
  }

  const LayoutFocusState._(this.semanticTarget);

  static final RegExp _semanticTargetPattern = RegExp(r'^[a-z]+(?:-[a-z]+)*$');

  final String semanticTarget;
}

/// Bounded, presentation-only state keyed exclusively by catalog declarations.
final class LayoutStateStore {
  LayoutStateStore(this.catalog);

  final LayoutCatalog catalog;
  final Map<LayoutStateNamespace, LayoutPresentationStateValue> _values = {};

  int get length => _values.length;

  LayoutPresentationStateValue? read(LayoutStateNamespace namespace) {
    _requireDeclared(namespace);
    return _values[namespace];
  }

  void write(
    LayoutStateNamespace namespace,
    LayoutPresentationStateValue value,
  ) {
    _requireDeclared(namespace);
    _values[namespace] = value;
  }

  void remove(LayoutStateNamespace namespace) {
    _requireDeclared(namespace);
    _values.remove(namespace);
  }

  void resetProfile(LayoutProfileId profileId) {
    _values.removeWhere((namespace, _) => namespace.profileId == profileId);
  }

  void resetAll() => _values.clear();

  void _requireDeclared(LayoutStateNamespace namespace) {
    if (!catalog.declaresStateNamespace(namespace)) {
      throw const FormatException('layout_state_namespace_unregistered');
    }
  }
}
