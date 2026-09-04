import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';

sealed class LayoutPresentationStateValue {
  const LayoutPresentationStateValue();

  LayoutStateValueKind get kind;
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

  @override
  LayoutStateValueKind get kind => LayoutStateValueKind.scroll;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutScrollState && other.offset == offset;

  @override
  int get hashCode => offset.hashCode;
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

  @override
  LayoutStateValueKind get kind => LayoutStateValueKind.paneExtent;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutPaneExtentState && other.extent == extent;

  @override
  int get hashCode => extent.hashCode;
}

final class LayoutExpansionState extends LayoutPresentationStateValue {
  const LayoutExpansionState(this.expanded);

  final bool expanded;

  @override
  LayoutStateValueKind get kind => LayoutStateValueKind.expansion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutExpansionState && other.expanded == expanded;

  @override
  int get hashCode => expanded.hashCode;
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

  @override
  LayoutStateValueKind get kind => LayoutStateValueKind.tab;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LayoutTabState && other.index == index;

  @override
  int get hashCode => index.hashCode;
}

/// Renderer-safe access to bounded layout state. The concrete catalog and
/// lifecycle remain owned by Application and composition.
abstract interface class LayoutStatePort {
  Object get catalogIdentity;
  Stream<void> get changes;
  bool declares(LayoutStateNamespace namespace);
  LayoutPresentationStateValue? read(LayoutStateNamespace namespace);
  void write(
    LayoutStateNamespace namespace,
    LayoutPresentationStateValue value,
  );
  void remove(LayoutStateNamespace namespace);
}
