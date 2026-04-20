# Bring Your Own LLM — Kite Agent Hub

Kite Agent Hub does **not** hold any LLM key on behalf of users. You
either add your own Anthropic or OpenAI key to the platform's
encrypted credentials vault, or you run a local model and point it at
the platform using your agent's `api_token`.

Three supported paths, ordered from easiest to most flexible:

## (a) Bare terminal model (Ollama / qwen / llama.cpp)

Runs entirely on your laptop. Zero SaaS cost.

```bash
# 1. Install Ollama and pull a model
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5:7b

# 2. Start Ollama (it auto-starts on macOS)
ollama serve &

# 3. Run the reference runner (polls Kite Agent Hub + Ollama for you)
export KAH_AGENT_TOKEN=kite_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export KAH_BASE_URL=https://kite-agent-hub.fly.dev
python3 priv/byo/qwen_runner.py
```

The runner pulls your agent's system prompt from `GET /api/v1/agents/me`,
hands it to Ollama's `/api/chat` endpoint, parses the JSON decision,
and POSTs it to `/api/v1/trades`. Swap `qwen2.5:7b` for any model
Ollama supports (`llama3.1:8b`, `mistral:7b`, etc.).

## (b) Claude Desktop / Claude Code via MCP

Zero glue code for MCP-aware clients. You paste a one-time config
into Claude Desktop / Claude Code and the platform shows up as tools:

```
{
  "mcpServers": {
    "kite-agent-hub": {
      "command": "node",
      "args": ["/path/to/kite-agent-hub/mcp-server/index.js"],
      "env": {
        "KAH_AGENT_TOKEN": "kite_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        "KAH_BASE_URL": "https://kite-agent-hub.fly.dev"
      }
    }
  }
}
```

After restart, Claude exposes `place_trade`, `list_positions`, and
`get_context` as tools. You drive the agent from your normal Claude
chat — no API keys you have to wire up yourself beyond the agent
token (which the platform generates for you).

See `mcp-server/README.md` for the full tool list.

## (c) Direct HTTP

Any language, any model, any client. Call the platform's REST API
directly:

```bash
curl -X POST https://kite-agent-hub.fly.dev/api/v1/trades \
  -H "Authorization: Bearer kite_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "market": "ETH-USDC",
    "action": "buy",
    "side": "long",
    "contracts": 1,
    "fill_price": "3250.00",
    "reason": "momentum break above 3200"
  }'
```

The only required auth is the per-agent `api_token`, generated on
agent creation and visible in the dashboard. Rate-limited to 10
req/s per agent (node-local).

---

## Frequently asked

**Does the platform ever call an LLM on my behalf?**
Only when **your org** has uploaded an Anthropic or OpenAI key into the
encrypted credentials vault. Otherwise the agent sits in
`{:hold, "byo_llm_mode"}` and waits for an external client to POST
trades on its token.

**Where are my LLM keys stored?**
AES-256-GCM encrypted at rest in the `api_credentials` table. The
virtual `:secret` field never touches the database in plaintext.

**What happens if my Anthropic / OpenAI key is invalid?**
The provider returns `{:error, :unauthorized}`, the signal is
dropped, and nothing crashes. Rotate the key in the dashboard.

**Can I use a hosted Ollama instance?**
Yes — set the `OLLAMA_BASE_URL` environment variable at the platform
level (ops-controlled). Per-agent `llm_endpoint_url` overrides are
planned behind an SSRF allow-list and are not yet enabled.
