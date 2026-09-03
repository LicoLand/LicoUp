import 'package:licoup/src/contracts/problem_codes/problem_code.dart';
import 'package:licoup/src/contracts/problem_codes/problem_code_domain.dart';

/// Legacy wire-code → problem-code map.
///
/// Inventory (surfaced codes mapped here):
/// - LU-RP 1000-1199 Stdio RPC, process IO, request-shape failures (22 assigned)
/// - LU-CV 1200-1499 Canonical Conversation store and group operations (11 assigned)
/// - LU-AG 1500-1899 Agent workspace conversation, dispatch, native session (50 assigned)
/// - LU-ST 1900-2199 Adaptive Flywheel / strategy envelope (28 assigned)
/// - LU-CL 2200-2399 Native CLI admission (16 assigned)
/// - LU-CS 2400-2499 Client state get/set (3 assigned)
/// - LU-SK 2500-2599 Skill Hub (6 assigned)
/// - LU-TG 2600-2699 Target scan and pins (5 assigned)
/// - LU-MR 2700-2899 Mobile relay pairing and command relay (10 assigned)
/// - LU-SM 2900-3199 Secure Mesh / secure agent sessions (20 assigned)
/// - LU-UP 3200-3299 In-client update (11 assigned)
/// - LU-GW 3300-3499 LLM Gateway and Telegram channel (21 assigned)
/// - LU-PL 3500-3599 Adapter plugins (11 assigned)
/// - LU-AR 3600-3699 Conversation archive / snapshots (3 assigned)
/// - LU-AW 3700-3899 Subagent MCP and Assistant workflow facade (11 assigned)
/// - LU-NA 3900-4699 Native agent driver ProtocolFailure codes (339 assigned)
/// - LU-CB 4700-4799 Catalog convergence (16 assigned)
/// - LU-MC 4800-4899 MCP transfer (6 assigned)
/// - LU-OC 4900-5199 Optional collaboration plugins (64 assigned)
/// - LU-SY 5200-5299 Shell, lifecycle, shared authorization (11 assigned)
/// - LU-US 5300-5399 Agent usage and resource scans (3 assigned)
/// - LU-LY 5400-5499 Layout catalog and presentation contracts (96 assigned)
/// - LU-RL 5500-5599 Release-acceptance UI harness (12 assigned)
///
/// Aliases share one problem code: `native_agent_transport_failed`,
/// `mcp_http_transport_failed`, and `subagent_transport_failed` →
/// `transport_failed`.
/// `native_agent_timeout` → `timeout`.
///
/// Intentionally unmapped (internal-only):
/// - Adaptive Flywheel Graph validator strings (`workflow_state_limit`, …)
///   collapsed at the strategy RPC envelope to `workflow_invalid`.
/// - Strategy store/reducer internals (`strategy_lease_lost`, …) collapsed to
///   StrategyFailureCode / `strategy_operation_failed`.
/// - Canonical Conversation store internals (`runtime_cursor_invalid`, …)
///   collapsed at stdio RPC to `command_failed`.
/// - Native `anyhow` strings that never appear as `error.code` or Dart
///   `failureCode` / `lastError` / `reasonCode`.
const Map<String, ProblemCode> problemCodeEntries = {
  // LU-RP Stdio RPC, process IO, request-shape failures
  'invalid_args': ProblemCode(ProblemDomain.rpc, 1000),
  'mcp_http_transport_failed': ProblemCode(ProblemDomain.rpc, 1001),
  'native_agent_transport_failed': ProblemCode(ProblemDomain.rpc, 1001),
  'subagent_transport_failed': ProblemCode(ProblemDomain.rpc, 1001),
  'transport_failed': ProblemCode(ProblemDomain.rpc, 1001),
  'native_agent_timeout': ProblemCode(ProblemDomain.rpc, 1002),
  'timeout': ProblemCode(ProblemDomain.rpc, 1002),
  'invalid_json': ProblemCode(ProblemDomain.rpc, 1003),
  'invalid_method': ProblemCode(ProblemDomain.rpc, 1004),
  'invalid_params': ProblemCode(ProblemDomain.rpc, 1005),
  'invalid_portable_data_dir': ProblemCode(ProblemDomain.rpc, 1006),
  'invalid_protocol': ProblemCode(ProblemDomain.rpc, 1007),
  'invalid_request': ProblemCode(ProblemDomain.rpc, 1008),
  'invalid_request_id': ProblemCode(ProblemDomain.rpc, 1009),
  'invalid_response': ProblemCode(ProblemDomain.rpc, 1010),
  'invalid_timeout': ProblemCode(ProblemDomain.rpc, 1011),
  'invalid_workflow_id': ProblemCode(ProblemDomain.rpc, 1012),
  'private_input_transport_required': ProblemCode(ProblemDomain.rpc, 1013),
  'process_local_shutdown_failed': ProblemCode(ProblemDomain.rpc, 1014),
  'request_too_large': ProblemCode(ProblemDomain.rpc, 1015),
  'response_too_large': ProblemCode(ProblemDomain.rpc, 1016),
  'service_disposed': ProblemCode(ProblemDomain.rpc, 1017),
  'setup_failed': ProblemCode(ProblemDomain.rpc, 1018),
  'start_failed': ProblemCode(ProblemDomain.rpc, 1019),
  'streaming_command_unsupported': ProblemCode(ProblemDomain.rpc, 1020),
  'workflow_mismatch': ProblemCode(ProblemDomain.rpc, 1021),
  // LU-CV Canonical Conversation store and group operations
  'conversation_capacity_exhausted': ProblemCode(
    ProblemDomain.conversation,
    1200,
  ),
  'conversation_dispatch_failed': ProblemCode(ProblemDomain.conversation, 1201),
  'conversation_location_ambiguous': ProblemCode(
    ProblemDomain.conversation,
    1202,
  ),
  'conversation_location_unavailable': ProblemCode(
    ProblemDomain.conversation,
    1203,
  ),
  'conversation_not_found': ProblemCode(ProblemDomain.conversation, 1204),
  'conversation_persistence_failed': ProblemCode(
    ProblemDomain.conversation,
    1205,
  ),
  'conversation_state_unavailable': ProblemCode(
    ProblemDomain.conversation,
    1206,
  ),
  'invalid_conversation_location': ProblemCode(
    ProblemDomain.conversation,
    1207,
  ),
  'membership_not_runnable': ProblemCode(ProblemDomain.conversation, 1208),
  'persistent_conversation_transport_required': ProblemCode(
    ProblemDomain.conversation,
    1209,
  ),
  'profile_candidate_rejected': ProblemCode(ProblemDomain.conversation, 1210),
  'profile_intent_invalid': ProblemCode(ProblemDomain.conversation, 1211),
  'profile_intent_limit': ProblemCode(ProblemDomain.conversation, 1212),
  'profile_revision_stale': ProblemCode(ProblemDomain.conversation, 1213),
  'conversation_operation_failed': ProblemCode(
    ProblemDomain.conversation,
    1402,
  ),
  // LU-AG Agent workspace conversation, dispatch, native session
  'agent_conversation_dispatch_failed': ProblemCode(
    ProblemDomain.agentConversation,
    1500,
  ),
  'agent_id_required': ProblemCode(ProblemDomain.agentConversation, 1501),
  'agent_identifier_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1502,
  ),
  'agent_message_input_limit': ProblemCode(
    ProblemDomain.agentConversation,
    1503,
  ),
  'agent_message_missing': ProblemCode(ProblemDomain.agentConversation, 1504),
  'agent_runtime_unsupported': ProblemCode(
    ProblemDomain.agentConversation,
    1505,
  ),
  'attachment_transport_unsupported': ProblemCode(
    ProblemDomain.agentConversation,
    1506,
  ),
  'conversation_turn_duplicate_ignored': ProblemCode(
    ProblemDomain.agentConversation,
    1507,
  ),
  'conversation_turn_queue_full': ProblemCode(
    ProblemDomain.agentConversation,
    1508,
  ),
  'conversation_working_directory_invalid': ProblemCode(
    ProblemDomain.agentConversation,
    1509,
  ),
  'conversation_working_directory_mismatch': ProblemCode(
    ProblemDomain.agentConversation,
    1510,
  ),
  'conversation_working_directory_unavailable': ProblemCode(
    ProblemDomain.agentConversation,
    1511,
  ),
  'conversation_working_directory_unbounded': ProblemCode(
    ProblemDomain.agentConversation,
    1512,
  ),
  'dispatch_cancel_failed': ProblemCode(ProblemDomain.agentConversation, 1513),
  'dispatch_cancel_scope_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1514,
  ),
  'dispatch_cancel_session_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1515,
  ),
  'dispatch_cancel_unsupported': ProblemCode(
    ProblemDomain.agentConversation,
    1516,
  ),
  'dispatch_cleanup_failed': ProblemCode(ProblemDomain.agentConversation, 1517),
  'dispatch_cleanup_session_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1518,
  ),
  'dispatch_cleanup_unsupported': ProblemCode(
    ProblemDomain.agentConversation,
    1519,
  ),
  'dispatch_reattach_failed': ProblemCode(
    ProblemDomain.agentConversation,
    1520,
  ),
  'dispatch_session_id_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1521,
  ),
  'dispatch_steer_input_required': ProblemCode(
    ProblemDomain.agentConversation,
    1522,
  ),
  'dispatch_steer_outcome_unknown': ProblemCode(
    ProblemDomain.agentConversation,
    1523,
  ),
  'dispatch_steer_transport_unavailable': ProblemCode(
    ProblemDomain.agentConversation,
    1524,
  ),
  'dispatch_steer_unsupported': ProblemCode(
    ProblemDomain.agentConversation,
    1525,
  ),
  'dispatch_stream_incomplete': ProblemCode(
    ProblemDomain.agentConversation,
    1526,
  ),
  'evidence_incomplete': ProblemCode(ProblemDomain.agentConversation, 1527),
  'evidence_missing': ProblemCode(ProblemDomain.agentConversation, 1528),
  'evidence_stale_or_incomplete': ProblemCode(
    ProblemDomain.agentConversation,
    1529,
  ),
  'exact_session_resume_unavailable': ProblemCode(
    ProblemDomain.agentConversation,
    1530,
  ),
  'native_agent_executable_not_detected': ProblemCode(
    ProblemDomain.agentConversation,
    1531,
  ),
  'native_agent_executable_unavailable': ProblemCode(
    ProblemDomain.agentConversation,
    1532,
  ),
  'native_agent_model_not_discovered': ProblemCode(
    ProblemDomain.agentConversation,
    1533,
  ),
  'native_agent_reasoning_effort_not_discovered': ProblemCode(
    ProblemDomain.agentConversation,
    1534,
  ),
  'native_agent_runtime_profile_unavailable': ProblemCode(
    ProblemDomain.agentConversation,
    1535,
  ),
  'native_effective_settings_mismatch': ProblemCode(
    ProblemDomain.agentConversation,
    1536,
  ),
  'native_history_load_failed': ProblemCode(
    ProblemDomain.agentConversation,
    1537,
  ),
  'native_session_id_mismatch': ProblemCode(
    ProblemDomain.agentConversation,
    1538,
  ),
  'native_session_id_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1539,
  ),
  'native_session_id_missing_from_result': ProblemCode(
    ProblemDomain.agentConversation,
    1540,
  ),
  'native_session_open_failed': ProblemCode(
    ProblemDomain.agentConversation,
    1541,
  ),
  'native_session_unresolved': ProblemCode(
    ProblemDomain.agentConversation,
    1542,
  ),
  'official_native_lane_missing': ProblemCode(
    ProblemDomain.agentConversation,
    1543,
  ),
  'queued_conversation_session_unresolved': ProblemCode(
    ProblemDomain.agentConversation,
    1544,
  ),
  'runtime_evidence_binding_mismatch': ProblemCode(
    ProblemDomain.agentConversation,
    1545,
  ),
  'runtime_message_send_unavailable': ProblemCode(
    ProblemDomain.agentConversation,
    1546,
  ),
  'stream_protocol_failed': ProblemCode(ProblemDomain.agentConversation, 1547),
  'terminal_result_invalid': ProblemCode(ProblemDomain.agentConversation, 1548),
  'virtual_machine_connection_invalid': ProblemCode(
    ProblemDomain.agentConversation,
    1549,
  ),
  // LU-ST Adaptive Flywheel / strategy envelope
  'binding_incomplete': ProblemCode(ProblemDomain.strategy, 1900),
  'callback_conflict': ProblemCode(ProblemDomain.strategy, 1901),
  'callback_stale': ProblemCode(ProblemDomain.strategy, 1902),
  'definition_not_found': ProblemCode(ProblemDomain.strategy, 1903),
  'effect_failed': ProblemCode(ProblemDomain.strategy, 1904),
  'effect_in_doubt': ProblemCode(ProblemDomain.strategy, 1905),
  'effect_outcome_unknown': ProblemCode(ProblemDomain.strategy, 1906),
  'effect_temporarily_unavailable': ProblemCode(ProblemDomain.strategy, 1907),
  'package_duplicate_entry': ProblemCode(ProblemDomain.strategy, 1908),
  'package_entry_invalid': ProblemCode(ProblemDomain.strategy, 1909),
  'package_layout_invalid': ProblemCode(ProblemDomain.strategy, 1910),
  'package_resource_limit': ProblemCode(ProblemDomain.strategy, 1911),
  'package_too_large': ProblemCode(ProblemDomain.strategy, 1912),
  'package_unavailable': ProblemCode(ProblemDomain.strategy, 1913),
  'permit_denied': ProblemCode(ProblemDomain.strategy, 1914),
  'preparation_not_found': ProblemCode(ProblemDomain.strategy, 1915),
  'quota_exhausted': ProblemCode(ProblemDomain.strategy, 1916),
  'revision_conflict': ProblemCode(ProblemDomain.strategy, 1917),
  'run_not_found': ProblemCode(ProblemDomain.strategy, 1918),
  'run_not_retryable': ProblemCode(ProblemDomain.strategy, 1919),
  'runtime_drifted': ProblemCode(ProblemDomain.strategy, 1920),
  'runtime_unavailable': ProblemCode(ProblemDomain.strategy, 1921),
  'sandbox_unavailable': ProblemCode(ProblemDomain.strategy, 1922),
  'strategy_actor_quota_exhausted': ProblemCode(ProblemDomain.strategy, 1923),
  'strategy_operation_failed': ProblemCode(ProblemDomain.strategy, 1924),
  'strategy_run_start_failed': ProblemCode(ProblemDomain.strategy, 1925),
  'unsupported_action': ProblemCode(ProblemDomain.strategy, 1926),
  'workflow_invalid': ProblemCode(ProblemDomain.strategy, 1927),
  'graph_invalid': ProblemCode(ProblemDomain.strategy, 1928),
  'graph_preflight_rejected': ProblemCode(ProblemDomain.strategy, 1929),
  'graph_identity_rejected': ProblemCode(ProblemDomain.strategy, 1930),
  'strategy_idempotency_conflict': ProblemCode(ProblemDomain.strategy, 1931),
  // LU-CL Native CLI admission
  'cli_argument_bytes_exceeded': ProblemCode(ProblemDomain.cli, 2200),
  'cli_argument_count_exceeded': ProblemCode(ProblemDomain.cli, 2201),
  'cli_argument_unexpected': ProblemCode(ProblemDomain.cli, 2202),
  'cli_command_missing': ProblemCode(ProblemDomain.cli, 2203),
  'cli_command_unknown': ProblemCode(ProblemDomain.cli, 2204),
  'cli_json_invalid': ProblemCode(ProblemDomain.cli, 2205),
  'cli_operation_unsupported': ProblemCode(ProblemDomain.cli, 2206),
  'cli_option_constraint_violation': ProblemCode(ProblemDomain.cli, 2207),
  'cli_option_duplicate': ProblemCode(ProblemDomain.cli, 2208),
  'cli_option_unknown': ProblemCode(ProblemDomain.cli, 2209),
  'cli_option_value_missing': ProblemCode(ProblemDomain.cli, 2210),
  'cli_required_argument_missing': ProblemCode(ProblemDomain.cli, 2211),
  'cli_required_option_missing': ProblemCode(ProblemDomain.cli, 2212),
  'command_failed': ProblemCode(ProblemDomain.cli, 2213),
  'command_panicked': ProblemCode(ProblemDomain.cli, 2214),
  'command_usage': ProblemCode(ProblemDomain.cli, 2215),
  // LU-CS Client state get/set
  'invalid_collection': ProblemCode(ProblemDomain.clientState, 2400),
  'invalid_document': ProblemCode(ProblemDomain.clientState, 2401),
  'state_operation_failed': ProblemCode(ProblemDomain.clientState, 2402),
  // LU-SK Skill Hub
  'skill_delete_apply_failed': ProblemCode(ProblemDomain.skillHub, 2500),
  'skill_delete_plan_failed': ProblemCode(ProblemDomain.skillHub, 2501),
  'skill_hub_operation_failed': ProblemCode(ProblemDomain.skillHub, 2502),
  'skill_hub_preferences_save_failed': ProblemCode(
    ProblemDomain.skillHub,
    2503,
  ),
  'skill_usage_report_failed': ProblemCode(ProblemDomain.skillHub, 2504),
  'skill_usage_scan_failed': ProblemCode(ProblemDomain.skillHub, 2505),
  // LU-TG Target scan and pins
  'target_add_failed': ProblemCode(ProblemDomain.targets, 2600),
  'target_inspect_failed': ProblemCode(ProblemDomain.targets, 2601),
  'target_pin_save_failed': ProblemCode(ProblemDomain.targets, 2602),
  'target_scan_failed': ProblemCode(ProblemDomain.targets, 2603),
  'target_tab_order_save_failed': ProblemCode(ProblemDomain.targets, 2604),
  // LU-MR Mobile relay pairing and command relay
  'mobile_relay_authorization_required': ProblemCode(
    ProblemDomain.mobileRelay,
    2700,
  ),
  'mobile_relay_device_switch_failed': ProblemCode(
    ProblemDomain.mobileRelay,
    2701,
  ),
  'mobile_relay_pairing_claim_failed': ProblemCode(
    ProblemDomain.mobileRelay,
    2702,
  ),
  'mobile_relay_pairing_copy_failed': ProblemCode(
    ProblemDomain.mobileRelay,
    2703,
  ),
  'mobile_relay_pairing_create_failed': ProblemCode(
    ProblemDomain.mobileRelay,
    2704,
  ),
  'mobile_relay_pairing_invite_invalid': ProblemCode(
    ProblemDomain.mobileRelay,
    2705,
  ),
  'mobile_relay_pairing_refresh_failed': ProblemCode(
    ProblemDomain.mobileRelay,
    2706,
  ),
  'mobile_relay_station_configuration_failed': ProblemCode(
    ProblemDomain.mobileRelay,
    2707,
  ),
  'mobile_relay_station_required': ProblemCode(ProblemDomain.mobileRelay, 2708),
  'mobile_relay_sync_failed': ProblemCode(ProblemDomain.mobileRelay, 2709),
  // LU-SM Secure Mesh / secure agent sessions
  'secure_agent_sessions_result_invalid': ProblemCode(
    ProblemDomain.secureMesh,
    2900,
  ),
  'secure_mesh_approval_inbox_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2901,
  ),
  'secure_mesh_approval_request_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2902,
  ),
  'secure_mesh_approval_request_invalid': ProblemCode(
    ProblemDomain.secureMesh,
    2903,
  ),
  'secure_mesh_approval_resolve_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2904,
  ),
  'secure_mesh_approval_response_invalid': ProblemCode(
    ProblemDomain.secureMesh,
    2905,
  ),
  'secure_mesh_command_execution_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2906,
  ),
  'secure_mesh_device_trust_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2907,
  ),
  'secure_mesh_file_destination_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2908,
  ),
  'secure_mesh_file_route_failed': ProblemCode(ProblemDomain.secureMesh, 2909),
  'secure_mesh_file_sync_confirm_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2910,
  ),
  'secure_mesh_file_sync_confirmation_unavailable': ProblemCode(
    ProblemDomain.secureMesh,
    2911,
  ),
  'secure_mesh_file_sync_destination_invalid': ProblemCode(
    ProblemDomain.secureMesh,
    2912,
  ),
  'secure_mesh_file_sync_destination_missing': ProblemCode(
    ProblemDomain.secureMesh,
    2913,
  ),
  'secure_mesh_file_sync_draft_missing': ProblemCode(
    ProblemDomain.secureMesh,
    2914,
  ),
  'secure_mesh_file_sync_prepare_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2915,
  ),
  'secure_mesh_file_sync_source_invalid': ProblemCode(
    ProblemDomain.secureMesh,
    2916,
  ),
  'secure_mesh_kt_action_failed': ProblemCode(ProblemDomain.secureMesh, 2917),
  'secure_mesh_mls_action_failed': ProblemCode(ProblemDomain.secureMesh, 2918),
  'secure_mesh_status_refresh_failed': ProblemCode(
    ProblemDomain.secureMesh,
    2919,
  ),
  // LU-UP In-client update
  'client_update_apply_failed': ProblemCode(ProblemDomain.clientUpdate, 3200),
  'client_update_apply_invalid': ProblemCode(ProblemDomain.clientUpdate, 3201),
  'client_update_check_failed': ProblemCode(ProblemDomain.clientUpdate, 3202),
  'client_update_check_invalid': ProblemCode(ProblemDomain.clientUpdate, 3203),
  'client_update_check_missing_artifact_receipt': ProblemCode(
    ProblemDomain.clientUpdate,
    3204,
  ),
  'client_update_download_failed': ProblemCode(
    ProblemDomain.clientUpdate,
    3205,
  ),
  'client_update_download_invalid': ProblemCode(
    ProblemDomain.clientUpdate,
    3206,
  ),
  'client_update_verify_failed': ProblemCode(ProblemDomain.clientUpdate, 3209),
  'client_update_verify_invalid': ProblemCode(ProblemDomain.clientUpdate, 3210),
  // LU-GW LLM Gateway and Telegram channel
  'llm_api_key_credential_unavailable': ProblemCode(
    ProblemDomain.gateway,
    3300,
  ),
  'llm_api_key_system_keyring_unavailable': ProblemCode(
    ProblemDomain.gateway,
    3301,
  ),
  'llm_gateway_config_invalid': ProblemCode(ProblemDomain.gateway, 3302),
  'llm_gateway_credentials_control_denied': ProblemCode(
    ProblemDomain.gateway,
    3303,
  ),
  'llm_gateway_credentials_control_failed': ProblemCode(
    ProblemDomain.gateway,
    3304,
  ),
  'llm_gateway_credentials_control_unavailable': ProblemCode(
    ProblemDomain.gateway,
    3305,
  ),
  'llm_gateway_port_invalid': ProblemCode(ProblemDomain.gateway, 3306),
  'llm_gateway_session_credentials_unavailable': ProblemCode(
    ProblemDomain.gateway,
    3307,
  ),
  'llm_gateway_sidecar_missing': ProblemCode(ProblemDomain.gateway, 3308),
  'llm_gateway_start_failed': ProblemCode(ProblemDomain.gateway, 3309),
  'llm_gateway_stop_failed': ProblemCode(ProblemDomain.gateway, 3310),
  'service_not_running': ProblemCode(ProblemDomain.gateway, 3311),
  'telegram_gateway_agent_required': ProblemCode(ProblemDomain.gateway, 3312),
  'telegram_gateway_api_failed': ProblemCode(ProblemDomain.gateway, 3313),
  'telegram_gateway_conflict': ProblemCode(ProblemDomain.gateway, 3314),
  'telegram_gateway_failed': ProblemCode(ProblemDomain.gateway, 3315),
  'telegram_gateway_json_invalid': ProblemCode(ProblemDomain.gateway, 3316),
  'telegram_gateway_network_failed': ProblemCode(ProblemDomain.gateway, 3317),
  'telegram_gateway_open_failed': ProblemCode(ProblemDomain.gateway, 3318),
  'telegram_gateway_send_failed': ProblemCode(ProblemDomain.gateway, 3319),
  'telegram_gateway_token_invalid': ProblemCode(ProblemDomain.gateway, 3320),
  // LU-PL Adapter plugins
  'adapter_native_capability_duplicate': ProblemCode(
    ProblemDomain.plugins,
    3500,
  ),
  'adapter_native_capability_kind_invalid': ProblemCode(
    ProblemDomain.plugins,
    3501,
  ),
  'adapter_plugin_action_not_declared': ProblemCode(
    ProblemDomain.plugins,
    3502,
  ),
  'adapter_plugin_agent_duplicate': ProblemCode(ProblemDomain.plugins, 3503),
  'adapter_plugin_builtin_action_invalid': ProblemCode(
    ProblemDomain.plugins,
    3504,
  ),
  'adapter_plugin_catalog_invalid': ProblemCode(ProblemDomain.plugins, 3505),
  'adapter_plugin_catalog_refresh_failed': ProblemCode(
    ProblemDomain.plugins,
    3506,
  ),
  'adapter_plugin_entry_duplicate': ProblemCode(ProblemDomain.plugins, 3507),
  'adapter_plugin_lifecycle_action_invalid': ProblemCode(
    ProblemDomain.plugins,
    3508,
  ),
  'adapter_plugin_management_kind_invalid': ProblemCode(
    ProblemDomain.plugins,
    3509,
  ),
  'adapter_plugin_missing': ProblemCode(ProblemDomain.plugins, 3510),
  // LU-AR Conversation archive / snapshots
  'conversation_archive_destination_required': ProblemCode(
    ProblemDomain.archive,
    3600,
  ),
  'conversation_archive_operation_failed': ProblemCode(
    ProblemDomain.archive,
    3601,
  ),
  'snapshot_restore_failed': ProblemCode(ProblemDomain.archive, 3602),
  // LU-AW Subagent MCP and Assistant workflow facade
  'invalid_working_directory': ProblemCode(
    ProblemDomain.assistantWorkflow,
    3719,
  ),
  'main_agent_unbound': ProblemCode(ProblemDomain.assistantWorkflow, 3720),
  'scan_failed': ProblemCode(ProblemDomain.assistantWorkflow, 3723),
  'server_busy': ProblemCode(ProblemDomain.assistantWorkflow, 3724),
  'subagent_cancel_unavailable': ProblemCode(
    ProblemDomain.assistantWorkflow,
    3725,
  ),
  'subagent_model_required_for_effort': ProblemCode(
    ProblemDomain.assistantWorkflow,
    3726,
  ),
  'subagent_model_unavailable': ProblemCode(
    ProblemDomain.assistantWorkflow,
    3727,
  ),
  'subagent_output_limit': ProblemCode(ProblemDomain.assistantWorkflow, 3728),
  'subagent_reasoning_effort_unavailable': ProblemCode(
    ProblemDomain.assistantWorkflow,
    3729,
  ),
  'subagent_resume_unavailable': ProblemCode(
    ProblemDomain.assistantWorkflow,
    3730,
  ),
  'subagent_unavailable': ProblemCode(ProblemDomain.assistantWorkflow, 3731),
  // LU-NA Native agent driver ProtocolFailure codes
  'acp_authentication_required': ProblemCode(ProblemDomain.nativeAgent, 3900),
  'acp_client_method_unsupported': ProblemCode(ProblemDomain.nativeAgent, 3901),
  'acp_control_capacity': ProblemCode(ProblemDomain.nativeAgent, 3902),
  'acp_control_transport_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3903,
  ),
  'acp_final_message_missing': ProblemCode(ProblemDomain.nativeAgent, 3904),
  'acp_initialize_invalid': ProblemCode(ProblemDomain.nativeAgent, 3905),
  'acp_initialize_rejected': ProblemCode(ProblemDomain.nativeAgent, 3906),
  'acp_mcp_registration_invalid': ProblemCode(ProblemDomain.nativeAgent, 3907),
  'acp_native_session_not_found': ProblemCode(ProblemDomain.nativeAgent, 3908),
  'acp_process_cleanup_failed': ProblemCode(ProblemDomain.nativeAgent, 3909),
  'acp_process_exited': ProblemCode(ProblemDomain.nativeAgent, 3910),
  'acp_process_pipe_failed': ProblemCode(ProblemDomain.nativeAgent, 3911),
  'acp_process_start_failed': ProblemCode(ProblemDomain.nativeAgent, 3912),
  'acp_prompt_rejected': ProblemCode(ProblemDomain.nativeAgent, 3913),
  'acp_prompt_required': ProblemCode(ProblemDomain.nativeAgent, 3914),
  'acp_prompt_response_invalid': ProblemCode(ProblemDomain.nativeAgent, 3915),
  'acp_protocol_failed': ProblemCode(ProblemDomain.nativeAgent, 3916),
  'acp_protocol_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 3917),
  'acp_protocol_output_limit': ProblemCode(ProblemDomain.nativeAgent, 3918),
  'acp_protocol_read_failed': ProblemCode(ProblemDomain.nativeAgent, 3919),
  'acp_protocol_timeout': ProblemCode(ProblemDomain.nativeAgent, 3920),
  'acp_protocol_write_failed': ProblemCode(ProblemDomain.nativeAgent, 3921),
  'acp_request_cancelled': ProblemCode(ProblemDomain.nativeAgent, 3922),
  'acp_resume_unsupported': ProblemCode(ProblemDomain.nativeAgent, 3923),
  'acp_session_id_mismatch': ProblemCode(ProblemDomain.nativeAgent, 3924),
  'acp_session_id_missing': ProblemCode(ProblemDomain.nativeAgent, 3925),
  'acp_session_mismatch': ProblemCode(ProblemDomain.nativeAgent, 3926),
  'acp_session_rejected': ProblemCode(ProblemDomain.nativeAgent, 3927),
  'acp_session_update_invalid': ProblemCode(ProblemDomain.nativeAgent, 3928),
  'acp_setting_not_applied': ProblemCode(ProblemDomain.nativeAgent, 3929),
  'acp_setting_rejected': ProblemCode(ProblemDomain.nativeAgent, 3930),
  'acp_setting_response_invalid': ProblemCode(ProblemDomain.nativeAgent, 3931),
  'acp_setting_unsupported': ProblemCode(ProblemDomain.nativeAgent, 3932),
  'acp_turn_not_completed': ProblemCode(ProblemDomain.nativeAgent, 3933),
  'acp_user_interaction_required': ProblemCode(ProblemDomain.nativeAgent, 3934),
  'acp_working_directory_invalid': ProblemCode(ProblemDomain.nativeAgent, 3935),
  'acp_working_directory_required': ProblemCode(
    ProblemDomain.nativeAgent,
    3936,
  ),
  'antigravity_auth_required': ProblemCode(ProblemDomain.nativeAgent, 3937),
  'antigravity_authorize_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3938,
  ),
  'antigravity_cli_empty_output': ProblemCode(ProblemDomain.nativeAgent, 3939),
  'antigravity_cli_empty_prompt': ProblemCode(ProblemDomain.nativeAgent, 3940),
  'antigravity_cli_session_drift': ProblemCode(ProblemDomain.nativeAgent, 3941),
  'antigravity_cli_session_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    3942,
  ),
  'antigravity_cli_start_failed': ProblemCode(ProblemDomain.nativeAgent, 3943),
  'antigravity_cli_structured_transport_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3944,
  ),
  'antigravity_cli_timeout': ProblemCode(ProblemDomain.nativeAgent, 3945),
  'antigravity_cli_turn_failed': ProblemCode(ProblemDomain.nativeAgent, 3946),
  'antigravity_executable_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3947,
  ),
  'antigravity_hook_bridge_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3948,
  ),
  'antigravity_hook_receipt_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    3949,
  ),
  'approval_inbox_register_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    3950,
  ),
  'approval_park_capacity': ProblemCode(ProblemDomain.nativeAgent, 3951),
  'approval_park_unavailable': ProblemCode(ProblemDomain.nativeAgent, 3952),
  'claude_code_approval_park_disconnected': ProblemCode(
    ProblemDomain.nativeAgent,
    3953,
  ),
  'claude_code_authentication_required': ProblemCode(
    ProblemDomain.nativeAgent,
    3954,
  ),
  'claude_code_cleanup_requested': ProblemCode(ProblemDomain.nativeAgent, 3955),
  'claude_code_empty_prompt': ProblemCode(ProblemDomain.nativeAgent, 3956),
  'claude_code_exited': ProblemCode(ProblemDomain.nativeAgent, 3957),
  'claude_code_final_message_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    3958,
  ),
  'claude_code_input_encode_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    3959,
  ),
  'claude_code_invalid_effort': ProblemCode(ProblemDomain.nativeAgent, 3960),
  'claude_code_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 3961),
  'claude_code_invalid_permission_mode': ProblemCode(
    ProblemDomain.nativeAgent,
    3962,
  ),
  'claude_code_output_limit': ProblemCode(ProblemDomain.nativeAgent, 3963),
  'claude_code_pipe_failed': ProblemCode(ProblemDomain.nativeAgent, 3964),
  'claude_code_read_failed': ProblemCode(ProblemDomain.nativeAgent, 3965),
  'claude_code_session_capacity': ProblemCode(ProblemDomain.nativeAgent, 3966),
  'claude_code_session_id_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    3967,
  ),
  'claude_code_session_id_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    3968,
  ),
  'claude_code_session_mismatch': ProblemCode(ProblemDomain.nativeAgent, 3969),
  'claude_code_session_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3970,
  ),
  'claude_code_start_failed': ProblemCode(ProblemDomain.nativeAgent, 3971),
  'claude_code_supervisor_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    3972,
  ),
  'claude_code_timeout': ProblemCode(ProblemDomain.nativeAgent, 3973),
  'claude_code_transport_capacity': ProblemCode(
    ProblemDomain.nativeAgent,
    3974,
  ),
  'claude_code_turn_failed': ProblemCode(ProblemDomain.nativeAgent, 3975),
  'claude_code_user_interaction_required': ProblemCode(
    ProblemDomain.nativeAgent,
    3976,
  ),
  'claude_code_write_failed': ProblemCode(ProblemDomain.nativeAgent, 3977),
  'codex_app_server_cleanup_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    3978,
  ),
  'codex_app_server_exited': ProblemCode(ProblemDomain.nativeAgent, 3979),
  'codex_app_server_failed': ProblemCode(ProblemDomain.nativeAgent, 3980),
  'codex_app_server_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 3981),
  'codex_app_server_output_limit': ProblemCode(ProblemDomain.nativeAgent, 3982),
  'codex_app_server_pipe_failed': ProblemCode(ProblemDomain.nativeAgent, 3983),
  'codex_app_server_read_failed': ProblemCode(ProblemDomain.nativeAgent, 3984),
  'codex_app_server_start_failed': ProblemCode(ProblemDomain.nativeAgent, 3985),
  'codex_app_server_timeout': ProblemCode(ProblemDomain.nativeAgent, 3986),
  'codex_app_server_write_failed': ProblemCode(ProblemDomain.nativeAgent, 3987),
  'codex_executable_invalid': ProblemCode(ProblemDomain.nativeAgent, 3988),
  'codex_final_message_missing': ProblemCode(ProblemDomain.nativeAgent, 3989),
  'codex_initialize_failed': ProblemCode(ProblemDomain.nativeAgent, 3990),
  'codex_invalid_local_image': ProblemCode(ProblemDomain.nativeAgent, 3991),
  'codex_invalid_resume_target': ProblemCode(ProblemDomain.nativeAgent, 3992),
  'codex_invalid_sandbox': ProblemCode(ProblemDomain.nativeAgent, 3993),
  'codex_protocol_error': ProblemCode(ProblemDomain.nativeAgent, 3994),
  'codex_thread_open_failed': ProblemCode(ProblemDomain.nativeAgent, 3995),
  'codex_turn_not_completed': ProblemCode(ProblemDomain.nativeAgent, 3996),
  'codex_turn_start_failed': ProblemCode(ProblemDomain.nativeAgent, 3997),
  'codex_usage_limit_exceeded': ProblemCode(ProblemDomain.nativeAgent, 4239),
  'codex_user_interaction_required': ProblemCode(
    ProblemDomain.nativeAgent,
    3998,
  ),
  'copilot_state_open_failed': ProblemCode(ProblemDomain.nativeAgent, 3999),
  'copilot_state_read_failed': ProblemCode(ProblemDomain.nativeAgent, 4000),
  'copilot_state_schema_unrecognized': ProblemCode(
    ProblemDomain.nativeAgent,
    4001,
  ),
  'cursor_cli_cancelled': ProblemCode(ProblemDomain.nativeAgent, 4002),
  'cursor_cli_authentication_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4240,
  ),
  'cursor_cli_capability_incomplete': ProblemCode(
    ProblemDomain.nativeAgent,
    4003,
  ),
  'cursor_cli_create_chat_failed': ProblemCode(ProblemDomain.nativeAgent, 4004),
  'cursor_cli_create_chat_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4005,
  ),
  'cursor_cli_create_chat_timeout': ProblemCode(
    ProblemDomain.nativeAgent,
    4006,
  ),
  'cursor_cli_empty_prompt': ProblemCode(ProblemDomain.nativeAgent, 4007),
  'cursor_cli_execution_failed': ProblemCode(ProblemDomain.nativeAgent, 4241),
  'cursor_cli_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 4008),
  'cursor_cli_private_instructions_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4233,
  ),
  'cursor_cli_output_limit': ProblemCode(ProblemDomain.nativeAgent, 4009),
  'cursor_cli_model_unavailable': ProblemCode(ProblemDomain.nativeAgent, 4242),
  'cursor_cli_prompt_acknowledgement_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4237,
  ),
  'cursor_cli_prompt_acknowledgement_mismatch': ProblemCode(
    ProblemDomain.nativeAgent,
    4238,
  ),
  'cursor_cli_read_failed': ProblemCode(ProblemDomain.nativeAgent, 4010),
  'cursor_cli_rate_limited': ProblemCode(ProblemDomain.nativeAgent, 4243),
  'cursor_cli_session_identity_mismatch': ProblemCode(
    ProblemDomain.nativeAgent,
    4234,
  ),
  'cursor_cli_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4011),
  'cursor_cli_text_snapshot_diverged': ProblemCode(
    ProblemDomain.nativeAgent,
    4235,
  ),
  'cursor_cli_timeout': ProblemCode(ProblemDomain.nativeAgent, 4012),
  'cursor_cli_turn_failed': ProblemCode(ProblemDomain.nativeAgent, 4013),
  'cursor_cli_usage_limit_exceeded': ProblemCode(
    ProblemDomain.nativeAgent,
    4244,
  ),
  'cursor_cli_unterminated_json': ProblemCode(ProblemDomain.nativeAgent, 4236),
  'cursor_cli_workspace_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4014,
  ),
  'hermes_acp_absolute_cwd_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4015,
  ),
  'hermes_acp_approval_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4016,
  ),
  'hermes_acp_capability_mismatch': ProblemCode(
    ProblemDomain.nativeAgent,
    4017,
  ),
  'hermes_acp_capability_missing': ProblemCode(ProblemDomain.nativeAgent, 4018),
  'hermes_acp_cleanup_requested': ProblemCode(ProblemDomain.nativeAgent, 4019),
  'hermes_acp_exited': ProblemCode(ProblemDomain.nativeAgent, 4020),
  'hermes_acp_failed': ProblemCode(ProblemDomain.nativeAgent, 4021),
  'hermes_acp_final_message_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4022,
  ),
  'hermes_acp_initialize_failed': ProblemCode(ProblemDomain.nativeAgent, 4023),
  'hermes_acp_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 4024),
  'hermes_acp_mcp_registration_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4025,
  ),
  'hermes_acp_output_limit': ProblemCode(ProblemDomain.nativeAgent, 4026),
  'hermes_acp_pipe_failed': ProblemCode(ProblemDomain.nativeAgent, 4027),
  'hermes_acp_probe_failed': ProblemCode(ProblemDomain.nativeAgent, 4028),
  'hermes_acp_prompt_failed': ProblemCode(ProblemDomain.nativeAgent, 4029),
  'hermes_acp_read_failed': ProblemCode(ProblemDomain.nativeAgent, 4030),
  'hermes_acp_reasoning_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4031,
  ),
  'hermes_acp_sandbox_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4032,
  ),
  'hermes_acp_session_id_missing': ProblemCode(ProblemDomain.nativeAgent, 4033),
  'hermes_acp_session_mismatch': ProblemCode(ProblemDomain.nativeAgent, 4034),
  'hermes_acp_session_open_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4035,
  ),
  'hermes_acp_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4036),
  'hermes_acp_supervisor_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4037,
  ),
  'hermes_acp_timeout': ProblemCode(ProblemDomain.nativeAgent, 4038),
  'hermes_acp_transport_capacity': ProblemCode(ProblemDomain.nativeAgent, 4039),
  'hermes_acp_turn_not_completed': ProblemCode(ProblemDomain.nativeAgent, 4040),
  'hermes_acp_write_failed': ProblemCode(ProblemDomain.nativeAgent, 4041),
  'native_interaction_transport_closed': ProblemCode(
    ProblemDomain.nativeAgent,
    4042,
  ),
  'hermes_empty_prompt': ProblemCode(ProblemDomain.nativeAgent, 4043),
  'hermes_gateway_absolute_cwd_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4044,
  ),
  'hermes_gateway_approval_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4045,
  ),
  'hermes_gateway_connection_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4046,
  ),
  'hermes_gateway_durable_session_id_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4047,
  ),
  'hermes_gateway_final_message_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4048,
  ),
  'hermes_gateway_live_session_id_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4049,
  ),
  'hermes_gateway_process_cleanup_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4050,
  ),
  'hermes_gateway_process_exited': ProblemCode(ProblemDomain.nativeAgent, 4051),
  'hermes_gateway_process_pipe_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4052,
  ),
  'hermes_gateway_process_start_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4053,
  ),
  'hermes_gateway_prompt_rejected': ProblemCode(
    ProblemDomain.nativeAgent,
    4054,
  ),
  'hermes_gateway_protocol_invalid_json': ProblemCode(
    ProblemDomain.nativeAgent,
    4055,
  ),
  'hermes_gateway_protocol_invalid_message': ProblemCode(
    ProblemDomain.nativeAgent,
    4056,
  ),
  'hermes_gateway_protocol_output_limit': ProblemCode(
    ProblemDomain.nativeAgent,
    4057,
  ),
  'hermes_gateway_protocol_read_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4058,
  ),
  'hermes_gateway_protocol_timeout': ProblemCode(
    ProblemDomain.nativeAgent,
    4059,
  ),
  'hermes_gateway_protocol_write_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4060,
  ),
  'hermes_gateway_reasoning_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4061,
  ),
  'hermes_gateway_resume_identity_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4062,
  ),
  'hermes_gateway_rpc_failed': ProblemCode(ProblemDomain.nativeAgent, 4063),
  'hermes_gateway_sandbox_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4064,
  ),
  'hermes_gateway_session_close_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4065,
  ),
  'hermes_gateway_session_history_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4066,
  ),
  'hermes_gateway_session_identity_mismatch': ProblemCode(
    ProblemDomain.nativeAgent,
    4067,
  ),
  'hermes_gateway_session_list_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4068,
  ),
  'hermes_gateway_session_resume_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4069,
  ),
  'hermes_gateway_user_interaction_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4070,
  ),
  'hermes_user_interaction_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4071,
  ),
  'kilo_code_serve_attach_probe_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4072,
  ),
  'kilo_code_serve_health_failed': ProblemCode(ProblemDomain.nativeAgent, 4073),
  'kilo_code_serve_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 4074),
  'kilo_code_serve_not_found': ProblemCode(ProblemDomain.nativeAgent, 4075),
  'kilo_code_serve_port_exhausted': ProblemCode(
    ProblemDomain.nativeAgent,
    4076,
  ),
  'kilo_code_serve_process_start_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4077,
  ),
  'kilo_code_serve_request_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4078,
  ),
  'kilo_code_serve_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4079),
  'kilo_code_serve_state_invalid': ProblemCode(ProblemDomain.nativeAgent, 4080),
  'kilo_code_serve_stop_failed': ProblemCode(ProblemDomain.nativeAgent, 4081),
  'kilo_code_serve_working_directory_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4082,
  ),
  'kilo_executable_missing': ProblemCode(ProblemDomain.nativeAgent, 4083),
  'kimi_code_acp_working_directory_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4084,
  ),
  'lico_agent_absolute_cwd_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4085,
  ),
  'lico_agent_executable_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4086,
  ),
  'lico_agent_model_required': ProblemCode(ProblemDomain.nativeAgent, 4087),
  'lico_agent_plan_path_required': ProblemCode(ProblemDomain.nativeAgent, 4088),
  'lico_agent_plan_reliable_sandbox_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4089,
  ),
  'lico_agent_plan_sandbox_path_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4090,
  ),
  'lico_agent_rpc_handshake_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4091,
  ),
  'lico_agent_rpc_handshake_timeout': ProblemCode(
    ProblemDomain.nativeAgent,
    4092,
  ),
  'lico_agent_rpc_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4093),
  'lico_agent_rpc_write_failed': ProblemCode(ProblemDomain.nativeAgent, 4094),
  'lico_agent_timeout': ProblemCode(ProblemDomain.nativeAgent, 4095),
  'lico_agent_turn_failed': ProblemCode(ProblemDomain.nativeAgent, 4096),
  'native_agent_authentication_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4097,
  ),
  'native_cancel_failed': ProblemCode(ProblemDomain.nativeAgent, 4098),
  'native_cancel_rejected': ProblemCode(ProblemDomain.nativeAgent, 4099),
  'native_terminal_failed': ProblemCode(ProblemDomain.nativeAgent, 4100),
  'openclaw_acp_absolute_cwd_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4101,
  ),
  'openclaw_acp_approval_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4102,
  ),
  'openclaw_acp_capability_mismatch': ProblemCode(
    ProblemDomain.nativeAgent,
    4103,
  ),
  'openclaw_acp_capability_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4104,
  ),
  'openclaw_acp_cleanup_failed': ProblemCode(ProblemDomain.nativeAgent, 4105),
  'openclaw_acp_conflicting_session_id': ProblemCode(
    ProblemDomain.nativeAgent,
    4106,
  ),
  'openclaw_acp_control_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4107,
  ),
  'openclaw_acp_exited': ProblemCode(ProblemDomain.nativeAgent, 4108),
  'openclaw_acp_failed': ProblemCode(ProblemDomain.nativeAgent, 4109),
  'openclaw_acp_final_message_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4110,
  ),
  'openclaw_acp_initialize_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4111,
  ),
  'openclaw_acp_invalid_agent_id': ProblemCode(ProblemDomain.nativeAgent, 4112),
  'openclaw_acp_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 4113),
  'openclaw_acp_invalid_thought_level': ProblemCode(
    ProblemDomain.nativeAgent,
    4114,
  ),
  'openclaw_acp_mcp_registration_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4115,
  ),
  'openclaw_acp_model_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4116,
  ),
  'openclaw_acp_native_session_id_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4117,
  ),
  'openclaw_acp_output_limit': ProblemCode(ProblemDomain.nativeAgent, 4118),
  'openclaw_acp_pipe_failed': ProblemCode(ProblemDomain.nativeAgent, 4119),
  'openclaw_acp_probe_failed': ProblemCode(ProblemDomain.nativeAgent, 4120),
  'openclaw_acp_prompt_failed': ProblemCode(ProblemDomain.nativeAgent, 4121),
  'openclaw_acp_read_failed': ProblemCode(ProblemDomain.nativeAgent, 4122),
  'openclaw_acp_sandbox_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4123,
  ),
  'openclaw_acp_session_id_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4124,
  ),
  'openclaw_acp_session_mismatch': ProblemCode(ProblemDomain.nativeAgent, 4125),
  'openclaw_acp_session_open_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4126,
  ),
  'openclaw_acp_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4127),
  'openclaw_acp_timeout': ProblemCode(ProblemDomain.nativeAgent, 4128),
  'openclaw_acp_turn_not_completed': ProblemCode(
    ProblemDomain.nativeAgent,
    4129,
  ),
  'openclaw_acp_write_failed': ProblemCode(ProblemDomain.nativeAgent, 4130),
  'openclaw_empty_prompt': ProblemCode(ProblemDomain.nativeAgent, 4131),
  'openclaw_executable_missing': ProblemCode(ProblemDomain.nativeAgent, 4132),
  'openclaw_gateway_health_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4133,
  ),
  'openclaw_gateway_port_exhausted': ProblemCode(
    ProblemDomain.nativeAgent,
    4134,
  ),
  'openclaw_gateway_remote_attach_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4135,
  ),
  'openclaw_gateway_remote_url_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4136,
  ),
  'openclaw_gateway_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4137),
  'openclaw_gateway_state_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4138,
  ),
  'openclaw_gateway_stop_failed': ProblemCode(ProblemDomain.nativeAgent, 4139),
  'openclaw_gateway_unavailable': ProblemCode(ProblemDomain.nativeAgent, 4140),
  'openclaw_user_interaction_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4141,
  ),
  'opencode_executable_missing': ProblemCode(ProblemDomain.nativeAgent, 4142),
  'opencode_serve_executable_missing': ProblemCode(
    ProblemDomain.nativeAgent,
    4142,
  ),
  'opencode_serve_attach_probe_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4143,
  ),
  'opencode_serve_health_failed': ProblemCode(ProblemDomain.nativeAgent, 4144),
  'opencode_serve_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 4145),
  'opencode_serve_not_found': ProblemCode(ProblemDomain.nativeAgent, 4146),
  'opencode_serve_port_exhausted': ProblemCode(ProblemDomain.nativeAgent, 4147),
  'opencode_serve_request_failed': ProblemCode(ProblemDomain.nativeAgent, 4148),
  'opencode_serve_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4149),
  'opencode_serve_state_invalid': ProblemCode(ProblemDomain.nativeAgent, 4150),
  'opencode_serve_stop_failed': ProblemCode(ProblemDomain.nativeAgent, 4151),
  'opencode_serve_working_directory_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4153,
  ),
  'opencode_turn_not_active': ProblemCode(ProblemDomain.nativeAgent, 4154),
  'pi_absolute_cwd_required': ProblemCode(ProblemDomain.nativeAgent, 4155),
  'pi_approval_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4156,
  ),
  'pi_empty_prompt': ProblemCode(ProblemDomain.nativeAgent, 4157),
  'pi_executable_unavailable': ProblemCode(ProblemDomain.nativeAgent, 4158),
  'pi_final_message_missing': ProblemCode(ProblemDomain.nativeAgent, 4159),
  'pi_gateway_credentials_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4160,
  ),
  'pi_invalid_thinking_level': ProblemCode(ProblemDomain.nativeAgent, 4161),
  'pi_model_provider_required': ProblemCode(ProblemDomain.nativeAgent, 4162),
  'pi_prompt_rejected': ProblemCode(ProblemDomain.nativeAgent, 4163),
  'pi_provider_turn_failed': ProblemCode(ProblemDomain.nativeAgent, 4164),
  'pi_rpc_cleanup_failed': ProblemCode(ProblemDomain.nativeAgent, 4165),
  'pi_rpc_exited': ProblemCode(ProblemDomain.nativeAgent, 4166),
  'pi_rpc_failed': ProblemCode(ProblemDomain.nativeAgent, 4167),
  'pi_rpc_invalid_json': ProblemCode(ProblemDomain.nativeAgent, 4168),
  'pi_rpc_output_limit': ProblemCode(ProblemDomain.nativeAgent, 4169),
  'pi_rpc_pipe_failed': ProblemCode(ProblemDomain.nativeAgent, 4170),
  'pi_rpc_read_failed': ProblemCode(ProblemDomain.nativeAgent, 4171),
  'pi_rpc_start_failed': ProblemCode(ProblemDomain.nativeAgent, 4172),
  'pi_rpc_timeout': ProblemCode(ProblemDomain.nativeAgent, 4173),
  'pi_rpc_write_failed': ProblemCode(ProblemDomain.nativeAgent, 4174),
  'pi_sandbox_override_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4175,
  ),
  'pi_session_id_missing': ProblemCode(ProblemDomain.nativeAgent, 4176),
  'pi_session_identity_ambiguous': ProblemCode(ProblemDomain.nativeAgent, 4177),
  'pi_session_identity_mismatch': ProblemCode(ProblemDomain.nativeAgent, 4178),
  'pi_session_not_found': ProblemCode(ProblemDomain.nativeAgent, 4179),
  'pi_session_state_failed': ProblemCode(ProblemDomain.nativeAgent, 4180),
  'pi_session_switch_cancelled': ProblemCode(ProblemDomain.nativeAgent, 4181),
  'pi_session_switch_failed': ProblemCode(ProblemDomain.nativeAgent, 4182),
  'pi_user_interaction_required': ProblemCode(ProblemDomain.nativeAgent, 4183),
  'remote_acp_agent_required': ProblemCode(ProblemDomain.nativeAgent, 4184),
  'remote_acp_initialize_failed': ProblemCode(ProblemDomain.nativeAgent, 4185),
  'remote_acp_initialize_request_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4186,
  ),
  'remote_acp_process_cleanup_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4187,
  ),
  'remote_acp_process_pipe_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4188,
  ),
  'remote_acp_process_start_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4189,
  ),
  'remote_acp_protocol_invalid_json': ProblemCode(
    ProblemDomain.nativeAgent,
    4190,
  ),
  'remote_acp_protocol_output_limit': ProblemCode(
    ProblemDomain.nativeAgent,
    4191,
  ),
  'remote_acp_protocol_read_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4192,
  ),
  'remote_acp_protocol_timeout': ProblemCode(ProblemDomain.nativeAgent, 4193),
  'remote_acp_protocol_write_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4194,
  ),
  'remote_acp_session_list_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4195,
  ),
  'remote_acp_session_list_request_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4196,
  ),
  'remote_acp_session_list_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4197,
  ),
  'remote_acp_session_load_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4198,
  ),
  'remote_acp_session_load_request_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4199,
  ),
  'remote_acp_session_load_unsupported': ProblemCode(
    ProblemDomain.nativeAgent,
    4200,
  ),
  'remote_acp_session_replay_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4201,
  ),
  'remote_acp_session_replay_limit': ProblemCode(
    ProblemDomain.nativeAgent,
    4202,
  ),
  'opencode_serve_authentication_required': ProblemCode(
    ProblemDomain.nativeAgent,
    4203,
  ),
  'opencode_serve_client_busy': ProblemCode(ProblemDomain.nativeAgent, 4204),
  'opencode_serve_protocol_write_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4205,
  ),
  'opencode_serve_rate_limited': ProblemCode(ProblemDomain.nativeAgent, 4206),
  'opencode_serve_request_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4207,
  ),
  'opencode_serve_request_rejected': ProblemCode(
    ProblemDomain.nativeAgent,
    4208,
  ),
  'opencode_serve_request_too_large': ProblemCode(
    ProblemDomain.nativeAgent,
    4209,
  ),
  'opencode_serve_response_headers_too_large': ProblemCode(
    ProblemDomain.nativeAgent,
    4210,
  ),
  'opencode_serve_session_busy': ProblemCode(ProblemDomain.nativeAgent, 4211),
  'opencode_serve_url_invalid': ProblemCode(ProblemDomain.nativeAgent, 4212),
  'pi_model_override_failed': ProblemCode(ProblemDomain.nativeAgent, 4213),
  'opencode_serve_cleanup_failed': ProblemCode(ProblemDomain.nativeAgent, 4214),
  'opencode_serve_control_capacity': ProblemCode(
    ProblemDomain.nativeAgent,
    4215,
  ),
  'opencode_serve_control_failed': ProblemCode(ProblemDomain.nativeAgent, 4216),
  'opencode_serve_deadline_exceeded': ProblemCode(
    ProblemDomain.nativeAgent,
    4217,
  ),
  'opencode_serve_health_timeout': ProblemCode(ProblemDomain.nativeAgent, 4218),
  'opencode_serve_message_failed': ProblemCode(ProblemDomain.nativeAgent, 4219),
  'opencode_serve_session_failed': ProblemCode(ProblemDomain.nativeAgent, 4220),
  'opencode_serve_session_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4221,
  ),
  'opencode_serve_sse_busy': ProblemCode(ProblemDomain.nativeAgent, 4222),
  'opencode_serve_sse_closed': ProblemCode(ProblemDomain.nativeAgent, 4223),
  'opencode_serve_sse_event_limit': ProblemCode(
    ProblemDomain.nativeAgent,
    4224,
  ),
  'opencode_serve_sse_frame_too_large': ProblemCode(
    ProblemDomain.nativeAgent,
    4225,
  ),
  'opencode_serve_sse_headers_too_large': ProblemCode(
    ProblemDomain.nativeAgent,
    4226,
  ),
  'opencode_serve_sse_invalid_json': ProblemCode(
    ProblemDomain.nativeAgent,
    4227,
  ),
  'opencode_serve_sse_invalid_utf8': ProblemCode(
    ProblemDomain.nativeAgent,
    4228,
  ),
  'opencode_serve_sse_line_too_large': ProblemCode(
    ProblemDomain.nativeAgent,
    4229,
  ),
  'opencode_serve_sse_request_failed': ProblemCode(
    ProblemDomain.nativeAgent,
    4230,
  ),
  'opencode_serve_sse_unavailable': ProblemCode(
    ProblemDomain.nativeAgent,
    4231,
  ),
  'opencode_serve_sse_url_invalid': ProblemCode(
    ProblemDomain.nativeAgent,
    4232,
  ),
  // LU-CB Catalog convergence
  'catalog_disabled': ProblemCode(ProblemDomain.catalog, 4700),
  'catalog_discovery_invalid': ProblemCode(ProblemDomain.catalog, 4701),
  'catalog_invalidation_invalid': ProblemCode(ProblemDomain.catalog, 4702),
  'catalog_invalidation_result_invalid': ProblemCode(
    ProblemDomain.catalog,
    4703,
  ),
  'catalog_not_configured': ProblemCode(ProblemDomain.catalog, 4704),
  'catalog_operation_unsupported': ProblemCode(ProblemDomain.catalog, 4705),
  'catalog_partition_capacity': ProblemCode(ProblemDomain.catalog, 4706),
  'catalog_reconciliation_failed': ProblemCode(ProblemDomain.catalog, 4707),
  'catalog_reconciling': ProblemCode(ProblemDomain.catalog, 4708),
  'catalog_refresh_rejected': ProblemCode(ProblemDomain.catalog, 4709),
  'catalog_snapshot_invalid': ProblemCode(ProblemDomain.catalog, 4710),
  'catalog_status_cohort_invalid': ProblemCode(ProblemDomain.catalog, 4711),
  'catalog_status_count_invalid': ProblemCode(ProblemDomain.catalog, 4712),
  'catalog_status_failed': ProblemCode(ProblemDomain.catalog, 4713),
  'catalog_status_revision_invalid': ProblemCode(ProblemDomain.catalog, 4714),
  'catalog_status_schema_invalid': ProblemCode(ProblemDomain.catalog, 4715),
  // LU-MC MCP transfer
  'mcp_transfer_confirmation_required': ProblemCode(ProblemDomain.mcp, 4800),
  'mcp_transfer_execute_failed': ProblemCode(ProblemDomain.mcp, 4801),
  'mcp_transfer_preview_failed': ProblemCode(ProblemDomain.mcp, 4802),
  'mcp_transfer_preview_invalid': ProblemCode(ProblemDomain.mcp, 4803),
  'mcp_transfer_preview_required': ProblemCode(ProblemDomain.mcp, 4804),
  'mcp_transfer_result_invalid': ProblemCode(ProblemDomain.mcp, 4805),
  // LU-OC Optional collaboration plugins
  'optional_collaboration_capability_disabled': ProblemCode(
    ProblemDomain.collaboration,
    4900,
  ),
  'optional_collaboration_digest_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4901,
  ),
  'optional_collaboration_disable_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4902,
  ),
  'optional_collaboration_disable_failed': ProblemCode(
    ProblemDomain.collaboration,
    4903,
  ),
  'optional_collaboration_enable_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4904,
  ),
  'optional_collaboration_enable_failed': ProblemCode(
    ProblemDomain.collaboration,
    4905,
  ),
  'optional_collaboration_git_commit_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4906,
  ),
  'optional_collaboration_github_url_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4907,
  ),
  'optional_collaboration_install_apply_failed': ProblemCode(
    ProblemDomain.collaboration,
    4908,
  ),
  'optional_collaboration_install_cancel_failed': ProblemCode(
    ProblemDomain.collaboration,
    4909,
  ),
  'optional_collaboration_install_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4910,
  ),
  'optional_collaboration_install_plan_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4911,
  ),
  'optional_collaboration_install_plan_failed': ProblemCode(
    ProblemDomain.collaboration,
    4912,
  ),
  'optional_collaboration_install_plan_required': ProblemCode(
    ProblemDomain.collaboration,
    4913,
  ),
  'optional_collaboration_list_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4914,
  ),
  'optional_collaboration_load_policy_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4915,
  ),
  'optional_collaboration_local_apply_failed': ProblemCode(
    ProblemDomain.collaboration,
    4916,
  ),
  'optional_collaboration_local_destination_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4917,
  ),
  'optional_collaboration_local_plan_failed': ProblemCode(
    ProblemDomain.collaboration,
    4918,
  ),
  'optional_collaboration_local_plan_required': ProblemCode(
    ProblemDomain.collaboration,
    4919,
  ),
  'optional_collaboration_local_selection_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4920,
  ),
  'optional_collaboration_local_server_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4921,
  ),
  'optional_collaboration_local_server_start_failed': ProblemCode(
    ProblemDomain.collaboration,
    4922,
  ),
  'optional_collaboration_local_server_start_state_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4923,
  ),
  'optional_collaboration_local_server_status_failed': ProblemCode(
    ProblemDomain.collaboration,
    4924,
  ),
  'optional_collaboration_local_server_stop_failed': ProblemCode(
    ProblemDomain.collaboration,
    4925,
  ),
  'optional_collaboration_local_server_stop_state_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4926,
  ),
  'optional_collaboration_local_server_uninstall_failed': ProblemCode(
    ProblemDomain.collaboration,
    4927,
  ),
  'optional_collaboration_local_server_uninstall_state_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4928,
  ),
  'optional_collaboration_mcp_apply_failed': ProblemCode(
    ProblemDomain.collaboration,
    4929,
  ),
  'optional_collaboration_mcp_catalog_policy_required': ProblemCode(
    ProblemDomain.collaboration,
    4930,
  ),
  'optional_collaboration_mcp_destinations_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4931,
  ),
  'optional_collaboration_mcp_plan_failed': ProblemCode(
    ProblemDomain.collaboration,
    4932,
  ),
  'optional_collaboration_mcp_plan_required': ProblemCode(
    ProblemDomain.collaboration,
    4933,
  ),
  'optional_collaboration_mcp_selection_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4934,
  ),
  'optional_collaboration_plugin_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4935,
  ),
  'optional_collaboration_plugin_required': ProblemCode(
    ProblemDomain.collaboration,
    4936,
  ),
  'optional_collaboration_runner_trust_change_requires_uninstall': ProblemCode(
    ProblemDomain.collaboration,
    4937,
  ),
  'optional_collaboration_runner_trust_changed': ProblemCode(
    ProblemDomain.collaboration,
    4938,
  ),
  'optional_collaboration_runner_trust_import_confirmation_required':
      ProblemCode(ProblemDomain.collaboration, 4939),
  'optional_collaboration_runner_trust_import_failed': ProblemCode(
    ProblemDomain.collaboration,
    4940,
  ),
  'optional_collaboration_runner_trust_input_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4941,
  ),
  'optional_collaboration_runner_trust_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4942,
  ),
  'optional_collaboration_runner_trust_missing': ProblemCode(
    ProblemDomain.collaboration,
    4943,
  ),
  'optional_collaboration_runner_trust_remove_confirmation_required':
      ProblemCode(ProblemDomain.collaboration, 4944),
  'optional_collaboration_runner_trust_remove_failed': ProblemCode(
    ProblemDomain.collaboration,
    4945,
  ),
  'optional_collaboration_runner_trust_remove_requires_uninstall': ProblemCode(
    ProblemDomain.collaboration,
    4946,
  ),
  'optional_collaboration_source_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4947,
  ),
  'optional_collaboration_status_failed': ProblemCode(
    ProblemDomain.collaboration,
    4948,
  ),
  'optional_collaboration_uninstall_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4949,
  ),
  'optional_collaboration_uninstall_digest_required': ProblemCode(
    ProblemDomain.collaboration,
    4950,
  ),
  'optional_collaboration_uninstall_failed': ProblemCode(
    ProblemDomain.collaboration,
    4951,
  ),
  'optional_collaboration_workflow_cancel_failed': ProblemCode(
    ProblemDomain.collaboration,
    4952,
  ),
  'optional_collaboration_workflow_catalog_failed': ProblemCode(
    ProblemDomain.collaboration,
    4953,
  ),
  'optional_collaboration_workflow_catalog_required': ProblemCode(
    ProblemDomain.collaboration,
    4954,
  ),
  'optional_collaboration_workflow_confirmation_required': ProblemCode(
    ProblemDomain.collaboration,
    4955,
  ),
  'optional_collaboration_workflow_kind_mismatch': ProblemCode(
    ProblemDomain.collaboration,
    4956,
  ),
  'optional_collaboration_workflow_plan_required': ProblemCode(
    ProblemDomain.collaboration,
    4957,
  ),
  'optional_local_server_adapter_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4958,
  ),
  'optional_local_server_bind_host_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4959,
  ),
  'optional_local_server_mutation_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4960,
  ),
  'optional_local_server_policy_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4961,
  ),
  'optional_local_server_port_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4962,
  ),
  'optional_local_server_status_invalid': ProblemCode(
    ProblemDomain.collaboration,
    4963,
  ),
  // LU-SY Shell, lifecycle, shared authorization
  'agent_hub_ordinary_capability_incomplete': ProblemCode(
    ProblemDomain.system,
    5200,
  ),
  'appearance_preset_reload_failed': ProblemCode(ProblemDomain.system, 5201),
  'authorization_failed': ProblemCode(ProblemDomain.system, 5202),
  'authorization_required': ProblemCode(ProblemDomain.system, 5203),
  'authorization_stale': ProblemCode(ProblemDomain.system, 5204),
  'client_workspace_manifest_incompatible': ProblemCode(
    ProblemDomain.system,
    5205,
  ),
  'current_view_agent_identity_invalid': ProblemCode(
    ProblemDomain.system,
    5206,
  ),
  'current_view_group_identity_invalid': ProblemCode(
    ProblemDomain.system,
    5207,
  ),
  'current_view_welcome_identity_invalid': ProblemCode(
    ProblemDomain.system,
    5208,
  ),
  'plan_document_invalid': ProblemCode(ProblemDomain.system, 5209),
  'workspace_manifest_not_an_object': ProblemCode(ProblemDomain.system, 5210),
  // LU-US Agent usage and resource scans
  'agent_resource_scan_failed': ProblemCode(ProblemDomain.usage, 5300),
  'agent_usage_reports_failed': ProblemCode(ProblemDomain.usage, 5301),
  'agent_usage_scan_failed': ProblemCode(ProblemDomain.usage, 5302),
  // LU-LY Layout catalog and presentation contracts
  'dashboard_desktop_destination_invalid': ProblemCode(
    ProblemDomain.layout,
    5400,
  ),
  'dashboard_desktop_surface_invalid': ProblemCode(ProblemDomain.layout, 5401),
  'dashboard_mobile_shell_contract_invalid': ProblemCode(
    ProblemDomain.layout,
    5402,
  ),
  'invalid_layout_profile_id': ProblemCode(ProblemDomain.layout, 5403),
  'layout_agents_presentation_missing': ProblemCode(ProblemDomain.layout, 5404),
  'layout_agents_strategy_missing': ProblemCode(ProblemDomain.layout, 5405),
  'layout_catalog_default_invalid': ProblemCode(ProblemDomain.layout, 5406),
  'layout_catalog_profile_duplicate': ProblemCode(ProblemDomain.layout, 5407),
  'layout_catalog_profile_missing': ProblemCode(ProblemDomain.layout, 5408),
  'layout_catalog_revision_invalid': ProblemCode(ProblemDomain.layout, 5409),
  'layout_catalog_variant_duplicate': ProblemCode(ProblemDomain.layout, 5410),
  'layout_catalog_variant_missing': ProblemCode(ProblemDomain.layout, 5411),
  'layout_catalog_variant_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5412,
  ),
  'layout_catalog_variant_profile_unknown': ProblemCode(
    ProblemDomain.layout,
    5413,
  ),
  'layout_catalog_variant_unregistered': ProblemCode(
    ProblemDomain.layout,
    5414,
  ),
  'layout_catalog_viewport_unsupported': ProblemCode(
    ProblemDomain.layout,
    5415,
  ),
  'layout_composition_bundle_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5416,
  ),
  'layout_composition_definition_missing': ProblemCode(
    ProblemDomain.layout,
    5417,
  ),
  'layout_composition_profile_duplicate': ProblemCode(
    ProblemDomain.layout,
    5418,
  ),
  'layout_definition_bundle_missing': ProblemCode(ProblemDomain.layout, 5419),
  'layout_definition_profile_mismatch': ProblemCode(ProblemDomain.layout, 5420),
  'layout_definition_surface_duplicate': ProblemCode(
    ProblemDomain.layout,
    5421,
  ),
  'layout_definition_surface_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5422,
  ),
  'layout_destination_contract_key_mismatch': ProblemCode(
    ProblemDomain.layout,
    5423,
  ),
  'layout_destination_contract_not_found': ProblemCode(
    ProblemDomain.layout,
    5424,
  ),
  'layout_destination_contract_registration_invalid': ProblemCode(
    ProblemDomain.layout,
    5425,
  ),
  'layout_destination_contract_type_mismatch': ProblemCode(
    ProblemDomain.layout,
    5426,
  ),
  'layout_destination_port_lease_foreign': ProblemCode(
    ProblemDomain.layout,
    5427,
  ),
  'layout_destination_port_lease_released': ProblemCode(
    ProblemDomain.layout,
    5428,
  ),
  'layout_destination_port_resolver_active_leases': ProblemCode(
    ProblemDomain.layout,
    5429,
  ),
  'layout_destination_port_resolver_closed': ProblemCode(
    ProblemDomain.layout,
    5430,
  ),
  'layout_environment_insets_invalid': ProblemCode(ProblemDomain.layout, 5431),
  'layout_environment_keyboard_inset_invalid': ProblemCode(
    ProblemDomain.layout,
    5432,
  ),
  'layout_environment_size_invalid': ProblemCode(ProblemDomain.layout, 5433),
  'layout_environment_text_scale_invalid': ProblemCode(
    ProblemDomain.layout,
    5434,
  ),
  'layout_environment_width_invalid': ProblemCode(ProblemDomain.layout, 5435),
  'layout_focus_target_invalid': ProblemCode(ProblemDomain.layout, 5436),
  'layout_host_catalog_mismatch': ProblemCode(ProblemDomain.layout, 5437),
  'layout_host_destination_unregistered': ProblemCode(
    ProblemDomain.layout,
    5438,
  ),
  'layout_manager_disposed': ProblemCode(ProblemDomain.layout, 5439),
  'layout_manager_listener_reentrancy': ProblemCode(ProblemDomain.layout, 5440),
  'layout_manager_not_initialized': ProblemCode(ProblemDomain.layout, 5441),
  'layout_manager_preferred_default_missing': ProblemCode(
    ProblemDomain.layout,
    5442,
  ),
  'layout_palette_scope_missing': ProblemCode(ProblemDomain.layout, 5443),
  'layout_profile_copy_invalid': ProblemCode(ProblemDomain.layout, 5444),
  'layout_profile_revision_invalid': ProblemCode(ProblemDomain.layout, 5445),
  'layout_profile_style_identity_invalid': ProblemCode(
    ProblemDomain.layout,
    5446,
  ),
  'layout_registry_profile_duplicate': ProblemCode(ProblemDomain.layout, 5447),
  'layout_registry_profile_mismatch': ProblemCode(ProblemDomain.layout, 5448),
  'layout_registry_profile_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5449,
  ),
  'layout_registry_profile_unregistered': ProblemCode(
    ProblemDomain.layout,
    5450,
  ),
  'layout_registry_state_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5451,
  ),
  'layout_registry_variant_duplicate': ProblemCode(ProblemDomain.layout, 5452),
  'layout_registry_variant_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5453,
  ),
  'layout_registry_variant_unregistered': ProblemCode(
    ProblemDomain.layout,
    5454,
  ),
  'layout_scope_missing': ProblemCode(ProblemDomain.layout, 5455),
  'layout_selection_candidate_invalid': ProblemCode(ProblemDomain.layout, 5456),
  'layout_selection_epoch_invalid': ProblemCode(ProblemDomain.layout, 5457),
  'layout_selection_error_state_invalid': ProblemCode(
    ProblemDomain.layout,
    5458,
  ),
  'layout_selection_viewport_invalid': ProblemCode(ProblemDomain.layout, 5459),
  'layout_selector_catalog_mismatch': ProblemCode(ProblemDomain.layout, 5460),
  'layout_settings_presentation_missing': ProblemCode(
    ProblemDomain.layout,
    5461,
  ),
  'layout_state_destination_invalid': ProblemCode(ProblemDomain.layout, 5462),
  'layout_state_namespace_duplicate': ProblemCode(ProblemDomain.layout, 5463),
  'layout_state_namespace_unregistered': ProblemCode(
    ProblemDomain.layout,
    5464,
  ),
  'layout_state_pane_extent_invalid': ProblemCode(ProblemDomain.layout, 5465),
  'layout_state_profile_unknown': ProblemCode(ProblemDomain.layout, 5466),
  'layout_state_scroll_invalid': ProblemCode(ProblemDomain.layout, 5467),
  'layout_state_surface_id_invalid': ProblemCode(ProblemDomain.layout, 5468),
  'layout_state_tab_invalid': ProblemCode(ProblemDomain.layout, 5469),
  'layout_state_value_kind_mismatch': ProblemCode(ProblemDomain.layout, 5470),
  'layout_surface_asset_namespace_invalid': ProblemCode(
    ProblemDomain.layout,
    5471,
  ),
  'layout_surface_destinations_missing': ProblemCode(
    ProblemDomain.layout,
    5472,
  ),
  'layout_surface_state_namespace_invalid': ProblemCode(
    ProblemDomain.layout,
    5473,
  ),
  'layout_surface_state_namespace_missing': ProblemCode(
    ProblemDomain.layout,
    5474,
  ),
  'layout_surface_style_identity_mismatch': ProblemCode(
    ProblemDomain.layout,
    5475,
  ),
  'layout_surface_viewport_key_mismatch': ProblemCode(
    ProblemDomain.layout,
    5476,
  ),
  'layout_surface_viewport_product_invalid': ProblemCode(
    ProblemDomain.layout,
    5477,
  ),
  'layout_variant_destinations_missing': ProblemCode(
    ProblemDomain.layout,
    5478,
  ),
  'layout_visual_tokens_invalid': ProblemCode(ProblemDomain.layout, 5479),
  'layout_visual_tokens_missing': ProblemCode(ProblemDomain.layout, 5480),
  'messaging_desktop_destination_mismatch': ProblemCode(
    ProblemDomain.layout,
    5481,
  ),
  'messaging_mobile_agents_destination_mismatch': ProblemCode(
    ProblemDomain.layout,
    5482,
  ),
  'messaging_mobile_text_scale_invalid': ProblemCode(
    ProblemDomain.layout,
    5483,
  ),
  'presentation_appearance_id_missing': ProblemCode(ProblemDomain.layout, 5484),
  'presentation_document_invalid': ProblemCode(ProblemDomain.layout, 5485),
  'presentation_locale_missing': ProblemCode(ProblemDomain.layout, 5486),
  'presentation_schema_unsupported': ProblemCode(ProblemDomain.layout, 5487),
  'semantic_destination_alias_cycle': ProblemCode(ProblemDomain.layout, 5488),
  'semantic_destination_alias_missing': ProblemCode(ProblemDomain.layout, 5489),
  'semantic_destination_duplicate': ProblemCode(ProblemDomain.layout, 5490),
  'semantic_destination_label_key_invalid': ProblemCode(
    ProblemDomain.layout,
    5491,
  ),
  'semantic_destination_product_incomplete': ProblemCode(
    ProblemDomain.layout,
    5492,
  ),
  'semantic_destination_self_alias': ProblemCode(ProblemDomain.layout, 5493),
  'semantic_destination_surface_empty': ProblemCode(ProblemDomain.layout, 5494),
  'semantic_destination_surface_missing': ProblemCode(
    ProblemDomain.layout,
    5495,
  ),
  // LU-RL Release-acceptance UI harness
  'release_ui_acceptance_target_not_enabled': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5500,
  ),
  'release_ui_composer_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5501,
  ),
  'release_ui_environment_invalid': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5502,
  ),
  'release_ui_first_completion_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5503,
  ),
  'release_ui_first_readback_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5504,
  ),
  'release_ui_first_stream_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5505,
  ),
  'release_ui_initialize_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5506,
  ),
  'release_ui_receipt_path_invalid': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5507,
  ),
  'release_ui_receipt_path_missing': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5508,
  ),
  'release_ui_second_completion_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5509,
  ),
  'release_ui_second_stream_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5510,
  ),
  'release_ui_target_scan_timeout': ProblemCode(
    ProblemDomain.releaseAcceptance,
    5511,
  ),
};
