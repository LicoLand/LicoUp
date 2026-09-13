import 'package:licoup/src/contracts/presentation/layout_environment.dart';

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
