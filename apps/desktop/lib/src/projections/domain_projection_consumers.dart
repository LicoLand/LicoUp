import 'package:licoup/src/projections/listenable_projection_consumer.dart';

final class AgentHubProjectionConsumer<T>
    extends ListenableProjectionConsumer<T> {
  AgentHubProjectionConsumer({required super.source, required super.read});
}

final class SettingsProjectionConsumer<T>
    extends ListenableProjectionConsumer<T> {
  SettingsProjectionConsumer({required super.source, required super.read});
}

final class TargetsProjectionConsumer<T>
    extends ListenableProjectionConsumer<T> {
  TargetsProjectionConsumer({required super.source, required super.read});
}

final class ShellProjectionConsumer<T> extends ListenableProjectionConsumer<T> {
  ShellProjectionConsumer({required super.source, required super.read});
}
