defmodule KiteAgentHub.Kite.SignalEngine do
  @moduledoc """
  LLM-powered trade signal generator for Kite agents.

  Calls Claude claude-haiku-4-5-20251001 with a structured prompt that includes:
  - The agent's configured strategy and risk parameters
  - Current market context (passed in as a map)
  - Recent trade history summary

  Returns a structured signal:
    {:ok, %{action: "buy"|"sell"|"hold", market: "ETH-USDC", contracts: integer,
            side: "long"|"short", fill_price: Decimal, reason: string, confidence: float}}

  Or {:hold, reason} if the LLM decides no trade is warranted.

  Usage:

      context = %{
        market: "ETH-USDC",
        price: "3250.00",
        trend: "bullish",
        rsi: 58,
        recent_trades: []
      }

      case SignalEngine.generate(agent, context) do
        {:ok, signal} -> TradeExecutionWorker.new(signal) |> Oban.insert()
        {:hold, _}    -> :noop
        {:error, _}   -> :retry_later
      end
  """

  require Logger

  alias KiteAgentHub.Trading.KiteAgent

  @anthropic_api "https://api.anthropic.com/v1/messages"
  @model "claude-haiku-4-5-20251001"
  @max_tokens 512

  @doc """
  Generate a trade signal for the given agent and market context.
  Returns {:ok, signal_map}, {:hold, reason}, or {:error, reason}.
  """
  def generate(%KiteAgent{} = agent, context) do
    case Application.get_env(:kite_agent_hub, :anthropic_api_key, "") do
      "" ->
        # BYO-LLM mode: no internal signal generation. Agents receive
        # trading decisions from external LLMs (Claude Code, etc.) via
        # the REST API using their api_token.
        {:hold, "byo_llm_mode"}

      api_key ->
        prompt = build_prompt(agent, context)

        case call_claude(api_key, prompt) do
          {:ok, text} -> parse_signal(text, context)
          {:error, _} = err -> err
        end
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_prompt(agent, context) do
    strategy = "general momentum trading on Kite chain"
    per_trade_limit = agent.per_trade_limit_usd || 1000
    daily_limit = agent.daily_limit_usd || 5000
    market = context[:market] || "ETH-USDC"
    price = context[:price] || "unknown"
    trend = context[:trend] || "neutral"
    rsi = context[:rsi]
    change_24h = context[:change_24h]
    recent = context[:recent_trades] || []

    recent_summary =
      case recent do
        [] ->
          "No recent trades."

        trades ->
          Enum.map_join(
            trades,
            "\n",
            &"- #{&1.action} #{&1.contracts}c @ #{&1.fill_price} (#{&1.status})"
          )
      end

    """
    You are a disciplined algorithmic trading agent operating on the Kite AI chain.
    Your job is to analyze the current market context and decide whether to trade.

    ## Agent Configuration
    - Strategy: #{strategy}
    - Per-trade limit: $#{per_trade_limit} notional
    - Daily spend limit: $#{daily_limit} notional

    ## Current Market Context
    - Market: #{market}
    - Price: #{price}
    - Trend: #{trend}
    #{if rsi, do: "- RSI (approx): #{rsi}", else: ""}
    #{if change_24h, do: "- 24h change: #{change_24h}%", else: ""}

    ## Recent Trade History
    #{recent_summary}

    ## Instructions
    Analyze the above and decide whether to place a trade now.
    Respond ONLY with a JSON object — no prose, no markdown fences.

    If you decide to trade:
    {
      "action": "buy" or "sell",
      "side": "long" or "short",
      "contracts": <integer 1-100>,
      "fill_price": "<price as decimal string>",
      "reason": "<one sentence>",
      "confidence": <0.0-1.0>
    }

    If you decide NOT to trade:
    {
      "action": "hold",
      "reason": "<one sentence>"
    }
    """
  end

  defp call_claude(api_key, prompt) do
    body = %{
      model: @model,
      max_tokens: @max_tokens,
      messages: [%{role: "user", content: prompt}]
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    case Req.post(@anthropic_api, json: body, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
        {:ok, text}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SignalEngine: Claude API error #{status}: #{inspect(body)}")
        {:error, "claude_api_#{status}"}

      {:error, reason} ->
        Logger.error("SignalEngine: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_signal(text, context) do
    market = context[:market] || "ETH-USDC"

    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```(?:json)?\s*/i, "")
      |> String.replace(~r/\s*```\s*$/, "")
      |> String.trim()

    with {:ok, parsed} <- Jason.decode(cleaned),
         "hold" <- Map.get(parsed, "action") == "hold" && "hold" do
      {:hold, parsed["reason"] || "no trade signal"}
    else
      {:ok, parsed} when is_map(parsed) ->
        action = parsed["action"]

        if action in ["buy", "sell"] do
          raw_contracts = parsed["contracts"] || 1
          contracts = max(1, min(raw_contracts, 100))

          signal = %{
            "action" => action,
            "side" => parsed["side"] || default_side(action),
            "market" => market,
            "contracts" => contracts,
            "fill_price" => parsed["fill_price"] || context[:price] || "0",
            "reason" => parsed["reason"] || "",
            "confidence" => parsed["confidence"] || 0.5
          }

          {:ok, signal}
        else
          {:hold, parsed["reason"] || "unknown action"}
        end

      {:error, _} ->
        Logger.warning("SignalEngine: failed to parse Claude response: #{inspect(text)}")
        {:error, "parse_error"}
    end
  end

  defp default_side("buy"), do: "long"
  defp default_side("sell"), do: "short"
  defp default_side(_), do: "long"
end
