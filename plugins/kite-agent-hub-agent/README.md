# Kite Agent Hub Agent Plugin

This local Codex plugin gives Codex a clean operating guide for Kite Agent Hub agents.

It includes prompt templates for all three KAH agent types:

- Research Agent
- Conversational Agent
- Trade Agent

It is intentionally token-safe:

- Do not paste API tokens into plugin files.
- Put the token in your shell as `KAH_API_TOKEN`.
- Keep live trading approval explicit.

## Fast terminal setup

```bash
cd /Users/damicomartin/kite-agent-hub
export KAH_API_TOKEN="paste_token_here"
codex "$(plugins/kite-agent-hub-agent/scripts/print-agent-prompt.sh research)"
```

Other agent modes:

```bash
codex "$(plugins/kite-agent-hub-agent/scripts/print-agent-prompt.sh conversational)"
codex "$(plugins/kite-agent-hub-agent/scripts/print-agent-prompt.sh trading)"
```

Users can rename their individual agents in the Kite Agent Hub site. These prompts use the generic default role names.

## Files

- `.codex-plugin/plugin.json` - Codex plugin metadata.
- `skills/kite-agent-hub-agent/SKILL.md` - Instructions Codex should follow when operating KAH.
- `prompts/research-test-agent.codex.md` - Research/trade-analysis prompt for Codex.
- `prompts/conversational-agent.codex.md` - Conversational Agent prompt.
- `prompts/trading-agent.codex.md` - Trade Agent prompt.
- `scripts/print-agent-prompt.sh` - Prints the requested prompt mode.
- `env.example` - Environment variable names to use locally.

## Safety

Only Trade Agent can submit trades. Research Agent researches and recommends. Conversational Agent chats, advises, and gives trading assistance without submitting orders. Trade Agent defaults to propose-first mode unless you explicitly grant autonomous trading for that session.
