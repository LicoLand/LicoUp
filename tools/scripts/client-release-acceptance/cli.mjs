import process from "node:process";

export function parseReleaseAcceptanceArgs(argv = process.argv.slice(2)) {
  const args = new Set(argv);
  return {
    args,
    selfTest: args.has("--self-test"),
    schemaFixture: args.has("--schema-fixture"),
  };
}
