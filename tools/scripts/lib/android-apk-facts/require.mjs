export function requireValue(condition, message) {
  if (!condition) throw new Error(message);
}
