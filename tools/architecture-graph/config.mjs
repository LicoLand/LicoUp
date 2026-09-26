/** Local graph analysis requires an explicit input; it is not repository policy. */
export const DEFAULT_RENDER_DIRECTORY = "build/reports/architecture-graph";
export const DEFAULT_PUBLIC_MAP = "build/reports/architecture-map.json";
export const GRAPH_SOURCE_CONTRACT = Object.freeze({
  project: "explicit --project input",
  architecture: "declared local graph input; not current-source authority",
  execution: "local execution input",
  distribution: "local deployment input when present",
  schemas: "a *.schema.json document beside each graph document",
  public_projection: DEFAULT_PUBLIC_MAP,
});
