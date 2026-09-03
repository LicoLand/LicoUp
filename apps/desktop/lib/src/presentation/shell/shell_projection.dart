import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

final class ShellLayout {
  const ShellLayout(this.selection);

  final LayoutSelectionState selection;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellLayout && other.selection == selection;

  @override
  int get hashCode => selection.hashCode;
}

final class ShellAppearance {
  ShellAppearance({
    required this.presetId,
    required List<AppearancePresetConfig> presetConfigs,
    required this.localePreference,
  }) : presetConfigs = List<AppearancePresetConfig>.unmodifiable(presetConfigs);

  final String presetId;
  final List<AppearancePresetConfig> presetConfigs;
  final String localePreference;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellAppearance &&
          other.presetId == presetId &&
          other.localePreference == localePreference &&
          _sameList(other.presetConfigs, presetConfigs);

  @override
  int get hashCode =>
      Object.hash(presetId, localePreference, Object.hashAll(presetConfigs));
}

final class ShellEnvironment {
  const ShellEnvironment({required this.mobileSurface});

  final bool mobileSurface;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellEnvironment && other.mobileSurface == mobileSurface;

  @override
  int get hashCode => mobileSurface.hashCode;
}

final class ShellStatus {
  const ShellStatus({
    required this.displayMessage,
    required this.displayCaption,
    required this.errorCode,
  });

  final String displayMessage;
  final String displayCaption;
  final String errorCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellStatus &&
          other.displayMessage == displayMessage &&
          other.displayCaption == displayCaption &&
          other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(displayMessage, displayCaption, errorCode);
}

final class ShellProjection {
  const ShellProjection({
    required this.layout,
    required this.appearance,
    required this.environment,
    required this.status,
    required this.destination,
  });

  final ShellLayout layout;
  final ShellAppearance appearance;
  final ShellEnvironment environment;
  final ShellStatus status;
  final ClientSection destination;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellProjection &&
          other.layout == layout &&
          other.appearance == appearance &&
          other.environment == environment &&
          other.status == status &&
          other.destination == destination;

  @override
  int get hashCode =>
      Object.hash(layout, appearance, environment, status, destination);
}

bool _sameList<T>(List<T> left, List<T> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
