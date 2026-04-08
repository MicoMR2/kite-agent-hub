#!/usr/bin/env node
/**
 * KAH MCP Server — Kite Agent Hub tools for Claude Desktop
 *
 * Exposes trading tools that call the KAH REST API:
 *   - get_portfolio: combined Alpaca + Kalshi portfolio view
 *   - place_trade: execute a trade on either platform
 *   - get_agents: list agents in the workspace
 *   - get_edge_score: run edge scoring on current market data
 *   - send_chat_message: post a message to the agent chat
 *   - get_trades: list recent trade history
 *
 * Auth: KAH agent api_token passed via env var KAH_AGENT_TOKEN
 * Base URL: env var KAH_BASE_URL (default: https://kite-agent-hub.fly.dev)
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const KAH_BASE_URL = process.env.KAH_BASE_URL || "https://kite-agent-hub.fly.dev";
const KAH_TOKEN = process.env.KAH_AGENT_TOKEN;

if (!KAH_TOKEN) {
  console.error("Error: KAH_AGENT_TOKEN environment variable is required");
  process.exit(1);
}

// --- HTTP helper ---
async function kahFetch(method, path, body = null) {
  const url = `${KAH_BASE_URL}${path}`;
  const opts = {
    method,
    headers: {
      "Authorization": `Bearer ${KAH_TOKEN}`,
      "Content-Type": "application/json",
    },
  };
  if (body) opts.body = JSON.stringify(body);

  const res = await fetch(url, opts);
  const text = await res.text();
  try {
    return { status: res.status, data: JSON.parse(text) };
  } catch {
    return { status: res.status, data: text };
  }
}

// --- MCP Server ---
const server = new McpServer({
  name: "kah",
  version: "1.0.0",
});

// Tool: get_portfolio
server.tool(
  "get_portfolio",
  "Get combined portfolio view — Alpaca account + Kalshi balance and positions",
  {},
  async () => {
    const agent = await kahFetch("GET", "/api/v1/agents/me");
    const trades = await kahFetch("GET", "/api/v1/trades?limit=10");

    return {
      content: [{
        type: "text",
        text: JSON.stringify({
          agent: agent.data,
          recent_trades: trades.data,
        }, null, 2),
      }],
    };
  }
);

// Tool: place_trade
server.tool(
  "place_trade",
  "Execute a trade on Alpaca or Kalshi via the KAH platform",
  {
    platform: z.enum(["alpaca", "kalshi"]).describe("Trading platform"),
    ticker: z.string().describe("Market ticker (e.g., AAPL, BTCZ-24DEC2031-B80000)"),
    side: z.enum(["buy", "sell"]).describe("Trade side"),
    amount: z.number().positive().describe("Trade amount in dollars or contracts"),
    reason: z.string().describe("Reason for the trade — include edge score"),
  },
  async ({ platform, ticker, side, amount, reason }) => {
    const result = await kahFetch("POST", "/api/v1/trades", {
      platform,
      ticker,
      side,
      amount,
      reason,
    });

    return {
      content: [{
        type: "text",
        text: result.status < 300
          ? `Trade executed: ${JSON.stringify(result.data, null, 2)}`
          : `Trade failed (${result.status}): ${JSON.stringify(result.data)}`,
      }],
    };
  }
);

// Tool: get_agents
server.tool(
  "get_agents",
  "List all trading agents in the KAH workspace",
  {},
  async () => {
    const result = await kahFetch("GET", "/api/v1/agents/me");
    return {
      content: [{
        type: "text",
        text: JSON.stringify(result.data, null, 2),
      }],
    };
  }
);

// Tool: get_edge_score
server.tool(
  "get_edge_score",
  "Get live QRB edge scores for all current Alpaca + Kalshi positions. Each position scored 0-100 across entry_quality, momentum, risk_reward, liquidity. Also returns exit/hold suggestions for weak/strong positions.",
  {},
  async () => {
    const result = await kahFetch("GET", "/api/v1/edge-scores");

    return {
      content: [{
        type: "text",
        text: result.status < 300
          ? JSON.stringify(result.data, null, 2)
          : `Failed to fetch edge scores (${result.status}): ${JSON.stringify(result.data)}`,
      }],
    };
  }
);

// Tool: send_chat_message
server.tool(
  "send_chat_message",
  "Send a message to the KAH agent chat — visible to the human operator and other agents",
  {
    text: z.string().min(1).describe("Message text to send"),
  },
  async ({ text }) => {
    // Chat messages go through the KAH API
    const result = await kahFetch("POST", "/api/v1/chat", { text });

    return {
      content: [{
        type: "text",
        text: result.status < 300
          ? `Message sent: "${text}"`
          : `Failed to send (${result.status}): ${JSON.stringify(result.data)}`,
      }],
    };
  }
);

// Tool: get_trades
server.tool(
  "get_trades",
  "Get recent trade history for this agent",
  {
    limit: z.number().int().min(1).max(100).default(20).describe("Number of trades to return"),
  },
  async ({ limit }) => {
    const result = await kahFetch("GET", `/api/v1/trades?limit=${limit}`);
    return {
      content: [{
        type: "text",
        text: JSON.stringify(result.data, null, 2),
      }],
    };
  }
);

// --- Start ---
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("MCP server error:", err);
  process.exit(1);
});
