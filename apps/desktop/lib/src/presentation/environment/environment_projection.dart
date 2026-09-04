import 'package:licoup/src/contracts/presentation/layout_environment.dart';

final class EnvironmentState {
  const EnvironmentState({
    required this.environment,
    required this.runtimeSurface,
  });

  final LayoutEnvironment environment;
  final LayoutRuntimeSurface runtimeSurface;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EnvironmentState &&
          other.environment == environment &&
          other.runtimeSurface == runtimeSurface;

  @override
  int get hashCode => Object.hash(environment, runtimeSurface);
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

EnvironmentProjection resolveEnvironmentProjection(EnvironmentState state) =>
    EnvironmentProjection(
      environment: state.environment,
      runtimeSurface: state.runtimeSurface,
    );

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
