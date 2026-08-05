# LicoUp 本机 LLM Gateway

[English（规范版本）](llm-gateway.md)

权威实现位于 `domain/llm_gateway.rs`、`platform/llm_gateway_transport.rs` 和
`lico-llm-gateway` sidecar。Gateway 只监听回环地址，并按“客户端协议 + 请求模型”
精确路由，不使用全局当前供应商。

## 能力

- Codex 的 `/v1/responses` 可以转接到 Kimi 等 OpenAI Chat Completions 上游，
  包括工具调用、流事件以及有界 `previous_response_id` 历史。
- Claude Code 的 `/v1/messages` 可以按模型分别路由到 Anthropic Messages 或
  OpenAI Chat Completions 上游。
- Kimi、DeepSeek 与 Kilo API Key 分别存为独立的系统密钥库项目，并由 macOS 机主验证
  （Touch ID、可用时的 Face ID，或系统密码回退）保护；清单不返回密钥尾号或内容。
- 每次启动 Gateway 时由发起启动的 `licoup-cli` 完成一次机主验证（Touch ID 或
  系统密码回退）；sidecar 仅通过继承的文件描述符接收内存中的凭证交接，自身
  从不读取 Keychain。不带交接 fd 独立启动的 sidecar 仍按原路径在启动时验证一次。
  两种方式下密钥都只进入可清零的进程内租约，退出即销毁。7/30/60/90/180/365 天
  只是单次运行进程的最长有效期，不会跳过下次启动验证。
- 修改授权有效期不会撤销正在运行的 Gateway。当前进程继续沿用原租约，新周期从
  下次启动 Gateway 并完成机主验证后生效。
- Codex 与 Claude Code 的托管配置只指向本机回环 Gateway，上游 API Key 绝不复制到
  智能体配置文件。

## 配置格式

```json
{
  "schemaVersion": 1,
  "providers": [
    {
      "id": "kimi-chat",
      "baseUrl": "https://provider.example/v1",
      "protocol": "open_ai_chat_completions",
      "credentialProvider": "kimi",
      "credentialStyle": "bearer"
    }
  ],
  "routes": [
    {
      "clientProtocol": "open_ai_responses",
      "requestedModel": "kimi-for-codex",
      "providerId": "kimi-chat",
      "upstreamModel": "provider-model-id"
    }
  ]
}
```

内置默认目录定义 Kimi、DeepSeek 与 Kilo 供应商。路由表是
`domain/llm_gateway_default_catalog.rs` 中的封闭产品目录。在 Gateway 启动与
智能体配置 plan/apply 时，仅物化当前至少有一把未过期已存 API 密钥的供应商：
投影其路由与 OpenCode/Pi 模型列表；没有可用密钥的供应商被完全省略。若本机
没有任何可用密钥，Gateway 配置为空且不展示任何模型。客户端可见的
`requestedModel` 使用 `{provider}:{alias}`（例如 `kimi:k3`、
`deepseek:deepseek-v4-flash`、`kilo:kilo-auto/free`）；`upstreamModel` 仍是厂商
或 Kilo API 的真实模型 id。精选 Kilo 集合包含稳定的 `kilo-auto/*` 档位与当前
上游命名 id。智能体配置适配器只展示有可用密钥的供应商的客户端别名。Kilo
托管目录有数百个模型；Gateway 保持显式精选子集，而不是代理整份远端列表。

配置文件必须是绝对路径、普通文件且不超过 1 MiB。可先用
`lico-llm-gateway --config <绝对路径> --check` 校验，再启动 sidecar；默认监听
`127.0.0.1:15722`。非回环 HTTP 端点、重定向、未知模型和未知字段都会关闭失败。

## 密钥托管

桌面设置页可保存多个 Kimi、DeepSeek 与 Kilo 密钥。输入框默认模糊，内容通过私有 stdin
传给原生 CLI。保存后没有查看、复制和修改操作，只能删除；删除会移除对应 Keychain
项目，并通过本机 epoch 标记撤销已运行进程的租约。

原生接口仅开放以下闭合操作：

- `llm-gateway credentials status`
- `llm-gateway credentials list`
- `llm-gateway credentials create --stdin-json true`
- `llm-gateway credentials delete <credential-id>`
- `llm-gateway credentials lease <days>`
- `llm-gateway service status`
- `llm-gateway service start [--port]`
- `llm-gateway service stop [--port]`
- `llm-gateway agent-config plan <codex|claude-code|opencode|pi> <绝对配置根目录>`

智能体配置命令只生成可审核且不含上游密钥的计划。Codex 使用官方自定义
`model_providers` profile 与 Responses API 基础地址；Claude Code 使用官方
`ANTHROPIC_BASE_URL`/`apiKeyHelper` Gateway 字段。OpenCode 只写入 sidecar
`opencode.licoup-gateway.json`（OpenAI Compatible Chat Completions），不会改写
`opencode.json` / `opencode.jsonc`；通过 `OPENCODE_CONFIG` 加载该 sidecar，由
OpenCode 与现有全局配置合并。Pi 只写入 sidecar `models.licoup-gateway.json`
（OpenAI Completions），不会整文件覆盖 `models.json`；一键脚本仅把
`providers.licoup-gateway` 合并进 `~/.pi/agent/models.json`。未知智能体在其精确
适配器加入统一运行时注册表之前一律关闭失败。

开发者一键脚本（同样的 sidecar 语义）：

```bash
npm run client:opencode:add-gateway
npm run client:pi:add-gateway
```
