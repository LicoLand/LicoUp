import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class EnvironmentState {
  const EnvironmentState({
    required this.environment,
    required this.runtimeSurface,
    this.systemReduceMotion = false,
  });

  final LayoutEnvironment environment;
  final LayoutRuntimeSurface runtimeSurface;
  final bool systemReduceMotion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnvironmentState &&
          other.environment == environment &&
          other.runtimeSurface == runtimeSurface &&
          other.systemReduceMotion == systemReduceMotion;

  @override
  int get hashCode =>
      Object.hash(environment, runtimeSurface, systemReduceMotion);
}

final class EnvironmentProjection {
  const EnvironmentProjection({
    required this.environment,
    required this.runtimeSurface,
    this.systemReduceMotion = false,
  });

  final LayoutEnvironment environment;
  final LayoutRuntimeSurface runtimeSurface;
  final bool systemReduceMotion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnvironmentProjection &&
          other.environment == environment &&
          other.runtimeSurface == runtimeSurface &&
          other.systemReduceMotion == systemReduceMotion;

  @override
  int get hashCode =>
      Object.hash(environment, runtimeSurface, systemReduceMotion);
}

EnvironmentProjection resolveEnvironmentProjection(EnvironmentState state) =>
    EnvironmentProjection(
      environment: state.environment,
      runtimeSurface: state.runtimeSurface,
      systemReduceMotion: state.systemReduceMotion,
    );

/// One installed language resource as the renderer consumes it.
///
/// The strings are the installed document itself: the renderer resolves an
/// interface key against the pack for its own locale and renders the installed
/// value, so what the user sees comes from the installed resource rather than
/// from the compiled baseline.
final class LocaleResourceProjection {
  LocaleResourceProjection({
    required this.id,
    required this.locale,
    required Map<String, String> strings,
  }) : strings = immutablePresentationMap(strings);

  /// The resource identity the installed package declared.
  final String id;

  /// The base language tag this resource supplies strings for.
  final String locale;

  /// Interface key to installed string.
  final Map<String, String> strings;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocaleResourceProjection &&
          other.id == id &&
          other.locale == locale &&
          samePresentationMap(other.strings, strings);

  @override
  int get hashCode =>
      Object.hash(id, locale, Object.hashAllUnordered(strings.entries));
}

final class LocaleProjection {
  const LocaleProjection(
    this.preference, {
    this.resources = const <LocaleResourceProjection>[],
  });

  final String preference;

  /// Language resources installed on this client, in load order.
  ///
  /// A first launch has none, and the interface then renders the strings
  /// compiled into the binary.
  final List<LocaleResourceProjection> resources;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LocaleProjection &&
          other.preference == preference &&
          samePresentationList(other.resources, resources);

  @override
  int get hashCode => Object.hash(preference, Object.hashAll(resources));
}
