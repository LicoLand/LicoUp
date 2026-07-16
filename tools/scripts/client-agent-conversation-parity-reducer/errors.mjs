export class ReducerError extends Error {
  constructor(code) {
    super(code);
    this.name = "ReducerError";
    this.code = code;
  }
}

export function fail(code) {
  throw new ReducerError(code);
}
