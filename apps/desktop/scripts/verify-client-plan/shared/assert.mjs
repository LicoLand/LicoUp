export function createPlanAssertions() {
  const failures = [];

  function assert(condition, message) {
    if (!condition) {
      failures.push(String(message || "client plan assertion failed"));
    }
  }

  function getFailures() {
    return [...failures];
  }

  return Object.freeze({ assert, getFailures });
}
