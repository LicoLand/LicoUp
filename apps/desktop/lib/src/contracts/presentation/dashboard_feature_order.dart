/// The frozen 功能 list identity for the Dashboard sidebar
/// (`dashboard-feature-order.json`): the semantic value shared by the
/// renderer-facing store port and its platform-backed implementation.
final class DashboardFeatureOrder {
  const DashboardFeatureOrder._();

  /// The visible 功能 entries in their default order.
  static const defaultOrder = <String>[
    'agentHub',
    'modelGateway',
    'mobilePairing',
    'statsPanel',
  ];
}
