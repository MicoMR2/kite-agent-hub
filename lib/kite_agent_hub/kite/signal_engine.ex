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

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.Kite.LLM.{Anthropic, OpenAI, Ollama}
  alias KiteAgentHub.Trading.KiteAgent

  @doc """
  Generate a trade signal for the given agent and market context.
  Returns {:ok, signal_map}, {:hold, reason}, or {:error, reason}.

  Provider dispatch order:
    1. per-agent `llm_provider` (uses agent.llm_model + the matching
       per-org Credentials.fetch_llm_key/2 for Anthropic/OpenAI)
    2. per-org credential: Anthropic then OpenAI
    3. shared `ANTHROPIC_API_KEY` shim (retired in a follow-up PR)
    4. `{:hold, "byo_llm_mode"}` — agent sits idle, external clients
       still drive trades via REST with the agent api_token
  """
  def generate(%KiteAgent{} = agent, context) do
    prompt = build_prompt(agent, context)

    case resolve_provider(agent) do
      {:ok, provider_mod, opts} ->
        case provider_mod.chat(prompt, opts) do
          {:ok, text} -> parse_signal(text, context)
          {:error, _} = err -> err
        end

      :hold ->
        {:hold, "byo_llm_mode"}
    end
  end

  # ── Provider resolution ─────────────────────────────────────────────────────

  defp resolve_provider(%KiteAgent{llm_provider: "anthropic"} = agent) do
    case Credentials.fetch_llm_key(agent.organization_id, "anthropic") do
      {:ok, key} -> {:ok, Anthropic, %{api_key: key, model: agent.llm_model}}
      _ -> resolve_org_or_shim(agent)
    end
  end

  defp resolve_provider(%KiteAgent{llm_provider: "openai"} = agent) do
    case Credentials.fetch_llm_key(agent.organization_id, "openai") do
      {:ok, key} -> {:ok, OpenAI, %{api_key: key, model: agent.llm_model}}
      _ -> resolve_org_or_shim(agent)
    end
  end

  defp resolve_provider(%KiteAgent{llm_provider: "ollama"} = agent) do
    # No API key needed. Deployer-controlled base URL is read inside
    # the Ollama impl — agent-supplied URLs land in a later PR behind
    # SSRF validation.
    {:ok, Ollama, %{model: agent.llm_model}}
  end

  defp resolve_provider(%KiteAgent{} = agent), do: resolve_org_or_shim(agent)

  defp resolve_org_or_shim(%KiteAgent{} = agent) do
    with {:error, _} <- Credentials.fetch_llm_key(agent.organization_id, "anthropic"),
         {:error, _} <- Credentials.fetch_llm_key(agent.organization_id, "openai") do
      case shared_anthropic_key() do
        key when is_binary(key) and key != "" -> {:ok, Anthropic, %{api_key: key}}
        _ -> :hold
      end
    else
      {:ok, key} ->
        # First non-error clause above matched — dispatch to the
        # corresponding provider. We re-check provider order to pick
        # the right module; Anthropic wins if both configured.
        case Credentials.fetch_llm_key(agent.organization_id, "anthropic") do
          {:ok, ^key} -> {:ok, Anthropic, %{api_key: key}}
          _ -> {:ok, OpenAI, %{api_key: key}}
        end
    end
  end

  defp shared_anthropic_key do
    Application.get_env(:kite_agent_hub, :anthropic_api_key, "")
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_prompt(_agent, context) do
    strategy = "general momentum trading on Kite chain"
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
