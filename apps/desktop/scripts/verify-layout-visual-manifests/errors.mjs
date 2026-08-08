export class LayoutVisualManifestError extends Error {
  constructor(code, relativePath = "") {
    super(relativePath ? `${code}: ${relativePath}` : code);
    this.name = "LayoutVisualManifestError";
    this.code = code;
    this.relativePath = relativePath;
  }
}

export function fail(code, relativePath = "") {
  throw new LayoutVisualManifestError(code, relativePath);
}
