export class LayoutBoundaryError extends Error {
  constructor(code, relativePath = "") {
    super(relativePath ? `${code}: ${relativePath}` : code);
    this.name = "LayoutBoundaryError";
    this.code = code;
    this.relativePath = relativePath;
  }
}

export function fail(code, relativePath = "") {
  throw new LayoutBoundaryError(code, relativePath);
}
