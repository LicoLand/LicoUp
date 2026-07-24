pub(super) const VENDOR_DEFAULT_PORT: u16 = 18789;
pub(super) const DEFAULT_PORT: u16 = 24189;
pub(super) const PORT_RANGE_SPAN: u16 = 16;
pub(super) const DEFAULT_HOST: &str = "127.0.0.1";
pub(super) const STATE_DIR: &str = "openclaw-gateway";
pub(super) const DEFAULT_HEALTH_TIMEOUT_MS: u64 = 60_000;
pub(super) const STATE_SCHEMA_VERSION: &str = "v0.0.1:openclaw-gateway-2";
pub(super) const INVALID_STATE: &str = "openclaw_gateway_state_invalid";
pub(super) const EXECUTABLE_MISSING: &str = "openclaw_executable_missing";
pub(super) const PORT_EXHAUSTED: &str = "openclaw_gateway_port_exhausted";
pub(super) const START_FAILED: &str = "openclaw_gateway_start_failed";
pub(super) const HEALTH_FAILED: &str = "openclaw_gateway_health_failed";
pub(super) const STOP_FAILED: &str = "openclaw_gateway_stop_failed";

pub(super) const RESERVED_PORTS: &[u16] = &[
    3000, 4096, 5173, 7228, 8080, 8443, 17328, 17329, 18765, 18789, 19001, 24173,
];
