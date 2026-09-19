import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Narrow immutable inputs of the plugin catalog region. Collaboration
/// updates never reach this region, and catalog updates never rebuild the
/// collaboration region.
final class PluginCatalogInputs {
  PluginCatalogInputs({
    required Iterable<PluginProjectionItem> plugins,
    required this.phase,
    required this.notice,
  }) : plugins = immutablePresentationList(plugins);

  final List<PluginProjectionItem> plugins;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginCatalogInputs &&
          samePresentationList(other.plugins, plugins) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(Object.hashAll(plugins), phase, notice);
}

/// Narrow immutable inputs of the optional collaboration region.
final class PluginCollaborationInputs {
  const PluginCollaborationInputs({
    required this.collaboration,
    required this.phase,
    required this.notice,
  });

  final CollaborationProjection collaboration;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginCollaborationInputs &&
          other.collaboration == collaboration &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(collaboration, phase, notice);
}
