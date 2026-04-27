# Handoff: Secret-Safe Codex Agent Prompts

## Problem

Codex refused to start KAH agents when users pasted the generated Option B command because the copied block included a live `KAH_API_TOKEN` value.

That refusal is expected: a bearer token in the pasted prompt or terminal command is treated as a secret.

## Change

- `KiteAgentHubWeb.CodexPrompts.combined_block/1` no longer interpolates `agent.api_token`.
- The copied Codex command now prompts locally in Terminal:
  - hides token input with `stty -echo`
  - exports `KAH_API_TOKEN`
  - starts `codex '<embedded prompt>'`
- Onboarding and dashboard copy now explain that users should enter the token only when Terminal asks.
- Claude-style prompts still include the token, but UI copy now warns those are only for trusted local coding clients.
- Plugin README setup now uses hidden terminal token entry instead of `export KAH_API_TOKEN="paste_token_here"`.

## Files

- `lib/kite_agent_hub_web/codex_prompts.ex`
- `lib/kite_agent_hub_web/live/onboard_live.ex`
- `lib/kite_agent_hub_web/live/dashboard_live.ex`
- `plugins/kite-agent-hub-agent/README.md`
- `test/kite_agent_hub_web/codex_prompts_test.exs`

## QA

Run:

```bash
mix format lib/kite_agent_hub_web/codex_prompts.ex test/kite_agent_hub_web/codex_prompts_test.exs
mix test test/kite_agent_hub_web/codex_prompts_test.exs
mix assets.build
```

Avoid running a broad format over the large LiveView files in this PR unless you intentionally want a format-only diff.

Manual check:

- Create or select an agent.
- Copy Option B.
- Confirm the copied block contains no `kite_...` token value.
- Paste into Codex Terminal.
- Confirm Terminal asks `Paste KAH agent token:`.
- Paste the token at that hidden prompt.
- Confirm Codex starts and the agent can use `$KAH_API_TOKEN` without the key appearing in Codex chat.
