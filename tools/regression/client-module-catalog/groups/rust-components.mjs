import {
  command,
  defineModule,
} from "../helpers.mjs";

export const RUST_COMPONENT_MODULES = Object.freeze([
  defineModule({
    id: "rust.component.analytics",
    kind: "rust-crate",
    summary: "Optional metrics correction/correlation and borrowed core-fact preservation on removal",
    inputs: [
      "components/analytics/**",
      "sdk/usage-source/**",
      "tests/integration/usage_sources/**",
      "crates/licoup-extension-contracts/src/usage.rs",
    ],
    command: command(
      "cargo",
      [
        "test",
        "--locked",
        "--offline",
        "--manifest-path",
        "components/analytics/Cargo.toml",
      ],
      20 * 60_000,
    ),
  }),
]);
