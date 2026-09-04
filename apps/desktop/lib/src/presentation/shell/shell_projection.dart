import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AppearanceTokenProjection {
  const AppearanceTokenProjection({required this.name, required this.value});

  final String name;
  final String value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceTokenProjection &&
          other.name == name &&
          other.value == value;

  @override
  int get hashCode => Object.hash(name, value);
}

final class AppearancePresetProjection {
  AppearancePresetProjection({
    required this.id,
    required this.label,
    required this.modeId,
    required Iterable<AppearanceTokenProjection> tokens,
  }) : tokens = immutablePresentationList(tokens);

  final String id;
  final String label;
  final String modeId;
  final List<AppearanceTokenProjection> tokens;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearancePresetProjection &&
          other.id == id &&
          other.label == label &&
          other.modeId == modeId &&
          samePresentationList(other.tokens, tokens);

  @override
  int get hashCode => Object.hash(id, label, modeId, Object.hashAll(tokens));
}

final class AppearanceProjection {
  AppearanceProjection({
    required this.presetId,
    required Iterable<AppearancePresetProjection> presets,
  }) : presets = immutablePresentationList(presets);

  final String presetId;
  final List<AppearancePresetProjection> presets;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppearanceProjection &&
          other.presetId == presetId &&
          samePresentationList(other.presets, presets);

  @override
  int get hashCode => Object.hash(presetId, Object.hashAll(presets));
}

final class LocaleProjection {
  const LocaleProjection(this.preference);

  final String preference;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocaleProjection && other.preference == preference;

  @override
  int get hashCode => preference.hashCode;
}

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

final class EnvironmentProjection {
  const EnvironmentProjection({
    required this.environment,
    required this.runtimeSurface,
  });

  final LayoutEnvironment environment;
  final LayoutRuntimeSurface runtimeSurface;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnvironmentProjection &&
          other.environment == environment &&
          other.runtimeSurface == runtimeSurface;

  @override
  int get hashCode => Object.hash(environment, runtimeSurface);
}

final class NavigationProjection {
  NavigationProjection({
    required this.destination,
    required Iterable<ClientSection> destinations,
  }) : destinations = immutablePresentationList(destinations);

  final ClientSection destination;
  final List<ClientSection> destinations;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NavigationProjection &&
          other.destination == destination &&
          samePresentationList(other.destinations, destinations);

  @override
  int get hashCode => Object.hash(destination, Object.hashAll(destinations));
}

final class StatusProjection {
  const StatusProjection({
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
      other is StatusProjection &&
          other.displayMessage == displayMessage &&
          other.displayCaption == displayCaption &&
          other.errorCode == errorCode;

  @override
  int get hashCode => Object.hash(displayMessage, displayCaption, errorCode);
}
