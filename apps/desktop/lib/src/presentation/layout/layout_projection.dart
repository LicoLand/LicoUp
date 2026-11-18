import 'package:licoup/src/contracts/presentation/layout_selection.dart';

final class LayoutProjection {
  const LayoutProjection(this.selection);

  final LayoutSelectionState selection;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutProjection && other.selection == selection;

  @override
  int get hashCode => selection.hashCode;
}
