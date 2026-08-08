export function parseJson(source) {
  try {
    return JSON.parse(String(source || ""));
  } catch {
    throw new Error("Android runtime status JSON is invalid");
  }
}
