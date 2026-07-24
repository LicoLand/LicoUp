use super::*;

pub(super) fn print_json(value: &Value) {
    println!(
        "{}",
        serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".to_string())
    );
}

pub(super) fn print_usage() {
    eprintln!(
        "Usage:
  licoup rpc stdio  # licoup.stdio.v1 line-delimited JSON RPC
  licoup state get|set <settings|targets|pairings|skills|pins|identities|conversation-archive-profiles|agent-usage-reports|skill-usage> [json]
  licoup adapter catalog
  licoup adapter antigravity status|install|uninstall
  licoup opencode-serve ensure|start|restart|stop|status [--port 24173] [--executable PATH] [--attach-url URL]
  licoup activity list [--type TYPE] [--target TARGET] [--limit N]
  licoup snapshots list [--target TARGET]
  licoup snapshots restore <snapshot-id>
  licoup snapshots root get|set [--path PATH]
  licoup snapshots collections list [--snapshot-root PATH]
  licoup snapshots profiles list|get|import [--profile PROFILE_ID|--profile-json JSON|--profile-file PATH]  # diagnostic
  licoup snapshots archive jobs preview (--selection-mode all|--selection-mode exact-keyword --query QUERY) --path PATH [--agent AGENT]
  licoup snapshots archive jobs create (--selection-mode all|--selection-mode exact-keyword --query QUERY) --path PATH --plan-binding SHA256 [--agent AGENT]
  licoup snapshots archive jobs status|events|cancel --job-id JOB_ID
  licoup snapshots archive jobs list|drain [--job-id JOB_ID] [--once true]
  licoup snapshots archive collect --keywords KEYWORDS --path PATH [--trigger manual|agent|scheduled]  # diagnostic
  licoup snapshots archive run|verify|report --profile PROFILE_ID [--trigger manual|agent|scheduled]  # diagnostic
  licoup snapshots archive verify --collection-path PATH
  licoup snapshots collect --topic TOPIC [--agent AGENT]
  licoup conversations list|append|delete|stream --agent AGENT [--limit N] [--offset N] [--session-id ID] [--text TEXT]
  licoup agent-usage scan [--agent AGENT] [--history-days DAYS] [--timezone-offset-minutes MINUTES] [--timezone-transitions-json JSON] [--force-refresh] [--state-root PATH]
  licoup agent-usage report [--agent AGENT] [--limit N] [--state-root PATH]
  licoup mcp http preview|execute --stdin-json true  # exact-scope private input and fresh platform user-presence confirmation
  licoup update status|check|download|verify|apply [--channel stable] [--manifest-path PATH] [--public-keys-path PATH] [--source-path PATH]
  licoup collaboration status|enable|disable|cleanup
  licoup collaboration install plan|apply|cancel [--github-url URL|--plan-id ID] [--expected-digest-sha256 SHA256] [--confirmed true]
  licoup collaboration workflow catalog
  licoup collaboration workflow local-deployment plan|apply --request-origin direct-user --selected-feature-ids IDS --destination PATH --destination-confirmed true [--port PORT --plan-id ID --expected-plan-digest-sha256 SHA256 --expected-package-digest-sha256 SHA256 --confirmed true]
  licoup collaboration local-server status
  licoup collaboration local-server start|stop --request-origin direct-user --deployment-id ID --confirmed true
  licoup collaboration local-server uninstall --request-origin direct-user --deployment-id ID --expected-assembly-manifest-digest-sha256 SHA256 --confirmed true
  licoup collaboration workflow mcp-install plan|apply --request-origin direct-user --selected-plugin-ids IDS --agent-destinations JSON [--plan-id ID --expected-plan-digest-sha256 SHA256 --expected-package-digest-sha256 SHA256 --confirmed true]
  licoup collaboration workflow cancel --request-origin direct-user --plan-id ID --expected-plan-digest-sha256 SHA256 --expected-package-digest-sha256 SHA256 --confirmed true
  licoup agent conversation open|send|steer|cancel|cleanup|capabilities|stream [--stdin-json true]
  licoup agents pair request|approve|revoke|list --agent AGENT [--target TARGET]
  licoup skill list --agent AGENT [--refresh-local true] [--install-root PATH]
  licoup skill get <skill-id> --agent AGENT [--discover-local true] [--install-root PATH]
  licoup skill install plan|apply --agent AGENT --url GITHUB_URL [--install-root PATH] [--name NAME] [--overwrite true|false] [--pin true|false]
  licoup skill install rollback --agent AGENT --snapshot-id ID
  licoup skill update plan --agent AGENT --skill SKILL [--source-path MIRROR_DIR|--url GITHUB_URL]
  licoup skill update apply --agent AGENT --skill SKILL --confirmation PLAN_VALUE [--source-path MIRROR_DIR|--url GITHUB_URL]
  licoup skill auto-update set --agent AGENT --skill SKILL --enabled true|false --direct-user-action true [--source-path MIRROR_DIR|--url GITHUB_URL]
  licoup skill auto-update run --agent AGENT --direct-user-action true [--skill SKILL]
  licoup skill auto-update tick
  licoup skill delete plan|apply --skill SKILL (--agent AGENT|--agents AGENT[,AGENT...]) [--confirmation PLAN_VALUE]
  licoup skill visibility set <skill-id> --agent AGENT --hidden true|false
  licoup skill pin set <skill-id> --agent AGENT --version VERSION
  licoup skill usage report [--agent AGENT] [--skill SKILL] [--days 1..365|--from YYYY-MM-DD] [--to YYYY-MM-DD]
  licoup targets scan [--state-root PATH] [--include-accessible-environments true|false] [--include-history-model-catalog true|false] [--installer-scan-command PATH]
  licoup targets add --target <target> [--config-path PATH] [--binary-path PATH] [--history-root PATH] [--state-root PATH]
  licoup targets inspect <target> [--state-root PATH]
  licoup mobile relay config get|set [--use-custom-gateway true|false] [--custom-gateway-url URL] [--relay-enabled true|false]
  licoup mobile relay pairing create|status|claim|revoke [--pairing-code CODE] [--pairing-id ID] [--mobile-token TOKEN]
  licoup mobile relay pc check-in
  licoup mobile relay commands poll|sync|complete|create|result|result-secure|result-replay-proof [--command-id ID] [--type TYPE] [--payload JSON] [--mobile-token TOKEN]
  licoup mobile relay e2ee secret-store-cleanup --disposable-proof true
  licoup secure-mesh status|envelope validate|command policy|command evaluate|command execute [--payload JSON] [--context JSON] [--ledger-path PATH]
  licoup secure-mesh device-trust evaluate --identity JSON [--previous-identity JSON] [--trust-state verified|cross_signed|unverified|key_changed|revoked]  # caller state is advisory and cannot authorize
  licoup secure-mesh file route --manifest JSON
  licoup secure-mesh file receive-destination --manifest JSON --approved-root PATH [--conflict-policy fail_if_exists|rename|overwrite_after_confirm]
  licoup secure-mesh approval request|fanout|respond|inbox|adapter-capability [--pending-operation-id ID] [--decision allow|deny]
  licoup secure-mesh file receive-confirmation --manifest JSON --approved-root PATH --user-confirmed true|false"
    );
}
