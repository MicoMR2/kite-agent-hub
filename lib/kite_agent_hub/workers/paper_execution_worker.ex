defmodule KiteAgentHub.Workers.PaperExecutionWorker do
  @moduledoc """
  Oban worker that dispatches paper-mode trade jobs to OANDA practice
  or Polymarket paper. Live order dispatch is intentionally rejected
  here — real-money routing is a separate PR with its own pre-build
  review.

  Enqueue via:

      %{
        "agent_id"        => agent.id,
        "organization_id" => org.id,
        "provider"        => "oanda_practice" | "polymarket",
        "symbol"          => "EUR_USD" | "0x<condition_id>",
        "side"            => "buy" | "sell" | "yes" | "no",
        "units"           => 100,
        # polymarket only:
        "token_id"        => "0x...",
        "price"           => "0.50"
      }
      |> KiteAgentHub.Workers.PaperExecutionWorker.new()
      |> Oban.insert()

  Guards:
    * provider must be in the allowlist — `"oanda_live"` is actively
      rejected at the entry point (CyberSec ②).
    * units > 0, symbol non-empty.
    * agent_type must be `"trading"`; non-trading agents are rejected
      before any platform call (CyberSec ④).
    * Polymarket dispatch asserts `mode: "paper"` — no live CLOB path
      exists in this worker (CyberSec ⑤).
    * Credentials are fetched from the encrypted store inside the
      platform module; job args never carry tokens or account ids
      (CyberSec ⑥).
  """

  use Oban.Worker,
    queue: :paper_execution,
    max_attempts: 3

  require Logger

  alias KiteAgentHub.{Trading, Oanda, Polymarket}

  @allowed_providers ~w(oanda_practice polymarket)

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    with :ok <- validate_provider(args["provider"]),
         :ok <- validate_symbol(args["symbol"]),
         :ok <- validate_units(args["units"]),
         {:ok, agent} <- load_agent(args["agent_id"]) do
      dispatch(agent, args, job_id)
    else
      {:error, reason} = err ->
        Logger.warning(
          "PaperExecutionWorker job=#{job_id} provider=#{inspect(args["provider"])} rejected: #{inspect(reason)}"
        )

        err
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  defp validate_provider(p) when p in @allowed_providers, do: :ok
  defp validate_provider("oanda_live"), do: {:error, :live_dispatch_not_allowed}
  defp validate_provider(_), do: {:error, :invalid_provider}

  defp validate_symbol(s) when is_binary(s) and byte_size(s) > 0, do: :ok
  defp validate_symbol(_), do: {:error, :invalid_symbol}

  defp validate_units(n) when is_integer(n) and n > 0, do: :ok
  defp validate_units(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> :ok
      _ -> {:error, :invalid_units}
    end
  end

  defp validate_units(_), do: {:error, :invalid_units}

  defp load_agent(nil), do: {:error, :missing_agent_id}

  defp load_agent(agent_id) do
    try do
      {:ok, Trading.get_agent!(agent_id)}
    rescue
      _ -> {:error, :agent_not_found}
    end
  end

  # ── Dispatch ───────────────────────────────────────────────────────────────

  defp dispatch(%{agent_type: "trading"} = agent, %{"provider" => "oanda_practice"} = args, job_id) do
    org_id = args["organization_id"]
    symbol = args["symbol"]

    units =
      case args["units"] do
        n when is_integer(n) -> signed_units(n, args["side"])
        n when is_binary(n) -> n |> String.to_integer() |> signed_units(args["side"])
      end

    case Oanda.place_practice_order(agent, org_id, symbol, units) do
      {:ok, body} ->
        Logger.info("PaperExecutionWorker job=#{job_id} provider=oanda_practice filled")
        {:ok, body}

      err ->
        Logger.warning(
          "PaperExecutionWorker job=#{job_id} provider=oanda_practice failed: #{inspect(err)}"
        )

        err
    end
  end

  defp dispatch(%{agent_type: "trading"} = agent, %{"provider" => "polymarket"} = args, job_id) do
    if args["mode"] in [nil, "paper"] do
      attrs = %{
        market_id: args["symbol"],
        token_id: args["token_id"] || args["symbol"],
        outcome: normalize_outcome(args["side"]),
        size: args["units"],
        price: args["price"],
        organization_id: args["organization_id"]
      }

      case Polymarket.place_paper_order(agent, attrs) do
        {:ok, pos} ->
          Logger.info("PaperExecutionWorker job=#{job_id} provider=polymarket paper-filled")
          {:ok, pos}

        err ->
          Logger.warning(
            "PaperExecutionWorker job=#{job_id} provider=polymarket failed: #{inspect(err)}"
          )

          err
      end
    else
      {:error, :polymarket_live_not_supported}
    end
  end

  defp dispatch(%{agent_type: _}, _args, job_id) do
    Logger.warning("PaperExecutionWorker job=#{job_id} rejected: not a trading agent")
    {:error, :not_a_trading_agent}
  end

  # OANDA expects signed units — positive for buy, negative for sell.
  defp signed_units(n, side) when is_integer(n) do
    case side do
      "sell" -> -abs(n)
      _ -> abs(n)
    end
  end

  defp normalize_outcome("yes"), do: "yes"
  defp normalize_outcome("no"), do: "no"
  defp normalize_outcome("buy"), do: "yes"
  defp normalize_outcome("sell"), do: "no"
  defp normalize_outcome(_), do: "yes"
end
