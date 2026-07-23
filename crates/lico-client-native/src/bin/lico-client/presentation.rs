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
  lico-client rpc stdio  # lico-client.stdio.v1 line-delimited JSON RPC
  lico-client state get|set <settings|targets|pairings|skills|pins|identities|conversation-archive-profiles|agent-usage-reports|skill-usage> [json]
  lico-client adapter catalog
  lico-client adapter antigravity status|install|uninstall
  lico-client opencode-serve ensure|start|restart|stop|status [--port 24173] [--executable PATH] [--attach-url URL]
  lico-client activity list [--type TYPE] [--target TARGET] [--limit N]
  lico-client snapshots list [--target TARGET]
  lico-client snapshots restore <snapshot-id>
  lico-client snapshots root get|set [--path PATH]
  lico-client snapshots collections list [--snapshot-root PATH]
  lico-client snapshots profiles list|get|import [--profile PROFILE_ID|--profile-json JSON|--profile-file PATH]  # diagnostic
  lico-client snapshots archive jobs preview (--selection-mode all|--selection-mode exact-keyword --query QUERY) --path PATH [--agent AGENT]
  lico-client snapshots archive jobs create (--selection-mode all|--selection-mode exact-keyword --query QUERY) --path PATH --plan-binding SHA256 [--agent AGENT]
  lico-client snapshots archive jobs status|events|cancel --job-id JOB_ID
  lico-client snapshots archive jobs list|drain [--job-id JOB_ID] [--once true]
  lico-client snapshots archive collect --keywords KEYWORDS --path PATH [--trigger manual|agent|scheduled]  # diagnostic
  lico-client snapshots archive run|verify|report --profile PROFILE_ID [--trigger manual|agent|scheduled]  # diagnostic
  lico-client snapshots archive verify --collection-path PATH
  lico-client snapshots collect --topic TOPIC [--agent AGENT]
  lico-client conversations list|append|delete|stream --agent AGENT [--limit N] [--offset N] [--session-id ID] [--text TEXT]
  lico-client agent-usage scan [--agent AGENT] [--history-days DAYS] [--timezone-offset-minutes MINUTES] [--timezone-transitions-json JSON] [--force-refresh] [--state-root PATH]
  lico-client agent-usage report [--agent AGENT] [--limit N] [--state-root PATH]
  lico-client mcp http preview|execute --stdin-json true  # exact-scope private input and fresh platform user-presence confirmation
  lico-client update status|check|download|verify|apply [--channel stable] [--manifest-path PATH] [--public-keys-path PATH] [--source-path PATH]
  lico-client collaboration status|enable|disable|cleanup
  lico-client collaboration install plan|apply|cancel [--github-url URL|--plan-id ID] [--expected-digest-sha256 SHA256] [--confirmed true]
  lico-client collaboration workflow catalog
  lico-client collaboration workflow local-deployment plan|apply --request-origin direct-user --selected-feature-ids IDS --destination PATH --destination-confirmed true [--port PORT --plan-id ID --expected-plan-digest-sha256 SHA256 --expected-package-digest-sha256 SHA256 --confirmed true]
  lico-client collaboration local-server status
  lico-client collaboration local-server start|stop --request-origin direct-user --deployment-id ID --confirmed true
  lico-client collaboration local-server uninstall --request-origin direct-user --deployment-id ID --expected-assembly-manifest-digest-sha256 SHA256 --confirmed true
  lico-client collaboration workflow mcp-install plan|apply --request-origin direct-user --selected-plugin-ids IDS --agent-destinations JSON [--plan-id ID --expected-plan-digest-sha256 SHA256 --expected-package-digest-sha256 SHA256 --confirmed true]
  lico-client collaboration workflow cancel --request-origin direct-user --plan-id ID --expected-plan-digest-sha256 SHA256 --expected-package-digest-sha256 SHA256 --confirmed true
  lico-client agent conversation open|send|steer|cancel|cleanup|capabilities|stream [--stdin-json true]
  lico-client agents pair request|approve|revoke|list --agent AGENT [--target TARGET]
  lico-client skill list --agent AGENT [--refresh-local true] [--install-root PATH]
  lico-client skill get <skill-id> --agent AGENT [--discover-local true] [--install-root PATH]
  lico-client skill install plan|apply --agent AGENT --url GITHUB_URL [--install-root PATH] [--name NAME] [--overwrite true|false] [--pin true|false]
  lico-client skill install rollback --agent AGENT --snapshot-id ID
  lico-client skill update plan --agent AGENT --skill SKILL [--source-path MIRROR_DIR|--url GITHUB_URL]
  lico-client skill update apply --agent AGENT --skill SKILL --confirmation PLAN_VALUE [--source-path MIRROR_DIR|--url GITHUB_URL]
  lico-client skill auto-update set --agent AGENT --skill SKILL --enabled true|false --direct-user-action true [--source-path MIRROR_DIR|--url GITHUB_URL]
  lico-client skill auto-update run --agent AGENT --direct-user-action true [--skill SKILL]
  lico-client skill auto-update tick
  lico-client skill delete plan|apply --skill SKILL (--agent AGENT|--agents AGENT[,AGENT...]) [--confirmation PLAN_VALUE]
  lico-client skill visibility set <skill-id> --agent AGENT --hidden true|false
  lico-client skill pin set <skill-id> --agent AGENT --version VERSION
  lico-client skill usage report [--agent AGENT] [--skill SKILL] [--days 1..365|--from YYYY-MM-DD] [--to YYYY-MM-DD]
  lico-client targets scan [--state-root PATH] [--include-accessible-environments true|false] [--include-history-model-catalog true|false] [--installer-scan-command PATH]
  lico-client targets add --target <target> [--config-path PATH] [--binary-path PATH] [--history-root PATH] [--state-root PATH]
  lico-client targets inspect <target> [--state-root PATH]
  lico-client mobile relay config get|set [--use-custom-gateway true|false] [--custom-gateway-url URL] [--relay-enabled true|false]
  lico-client mobile relay pairing create|status|claim|revoke [--pairing-code CODE] [--pairing-id ID] [--mobile-token TOKEN]
  lico-client mobile relay pc check-in
  lico-client mobile relay commands poll|sync|complete|create|result|result-secure|result-replay-proof [--command-id ID] [--type TYPE] [--payload JSON] [--mobile-token TOKEN]
  lico-client mobile relay e2ee secret-store-cleanup --disposable-proof true
  lico-client secure-mesh status|envelope validate|command policy|command evaluate|command execute [--payload JSON] [--context JSON] [--ledger-path PATH]
  lico-client secure-mesh device-trust evaluate --identity JSON [--previous-identity JSON] [--trust-state verified|cross_signed|unverified|key_changed|revoked]  # caller state is advisory and cannot authorize
  lico-client secure-mesh file route --manifest JSON
  lico-client secure-mesh file receive-destination --manifest JSON --approved-root PATH [--conflict-policy fail_if_exists|rename|overwrite_after_confirm]
  lico-client secure-mesh approval request|fanout|respond|inbox|adapter-capability [--pending-operation-id ID] [--decision allow|deny]
  lico-client secure-mesh file receive-confirmation --manifest JSON --approved-root PATH --user-confirmed true|false"
    );
}
