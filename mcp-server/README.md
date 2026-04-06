# KAH MCP Server

MCP (Model Context Protocol) server for Kite Agent Hub. Gives Claude Desktop native access to your trading platform.

## Setup

```bash
cd mcp-server
npm install
```

## Claude Desktop Configuration

Add to `~/.claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "kah": {
      "command": "node",
      "args": ["/path/to/kite-agent-hub/mcp-server/index.js"],
      "env": {
        "KAH_AGENT_TOKEN": "kite_your_agent_token_here",
        "KAH_BASE_URL": "https://kite-agent-hub.fly.dev"
      }
    }
  }
}
```

Get your agent token from the Agent Context button on the KAH dashboard.

## Available Tools

| Tool | Description |
|------|-------------|
| `get_portfolio` | Combined Alpaca + Kalshi portfolio view |
| `place_trade` | Execute a trade on either platform |
| `get_agents` | List agents in your workspace |
| `get_edge_score` | Get QRB edge scoring methodology + context |
| `send_chat_message` | Post to the agent chat thread |
| `get_trades` | List recent trade history |
