/// The traffic-light cluster's horizontal extents inside the window
/// frame — the reply the window-chrome channel returns for a traffic-light
/// anchor query. Owned by contracts so frontend and platform share the
/// type without a layer crossing.
typedef TrafficLightClusterEdges = ({double leading, double trailing});
