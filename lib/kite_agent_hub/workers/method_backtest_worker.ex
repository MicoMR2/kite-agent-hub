defmodule KiteAgentHub.Workers.MethodBacktestWorker do
  @moduledoc """
  Method-specific synthetic backtest seeder for the Kite Collective
  Intelligence corpus.

  Each run checks method-specific entry conditions before generating
  synthetic trade outcomes — unlike `KciSeederWorker` which always
  seeds regardless of market regime, this worker gates each method's
  backtest on whether its real conditions would have been met.

  ## M-007 Carry Trade (OANDA)

  Carry conditions (low realised volatility on the carry pair) are
  evaluated from the OANDA practice candle feed. If conditions are not
  met the worker logs a skip and exits cleanly — no synthetic rows are
  written and the corpus is not polluted with carry wins from high-vol
  regimes.

  ### Carry pairs seeded
  Classic long high-yield / short low-yield pairs:
  - AUD_JPY  (AUD: ~4% rate, JPY: ~0% rate — canonical carry)
  - NZD_JPY  (NZD: ~5% rate, JPY: ~0% rate)
  - AUD_CHF  (AUD: ~4% rate, CHF: ~1.5% rate)

  Manual trigger from iex:

      KiteAgentHub.Workers.MethodBacktestWorker.new(%{}) |> Oban.insert()
      # Specific org:
      KiteAgentHub.Workers.MethodBacktestWorker.new(%{"org_id" => "..."}) |> Oban.insert()
      # Single method:
      KiteAgentHub.Workers.MethodBacktestWorker.new(%{"method" => "m007"}) |> Oban.insert()
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  require Logger

  alias KiteAgentHub.{CollectiveIntelligence, Oanda, Repo}
  alias KiteAgentHub.CollectiveIntelligence.MethodSeeder
  alias KiteAgentHub.Credentials.ApiCredential

  import Ecto.Query

  # M-007 carry pairs: OANDA instrument format (BASE_QUOTE).
  @m007_carry_pairs ~w(AUD_JPY NZD_JPY AUD_CHF)

  # Fetch 90 daily bars — enough to compute a 60-day realised vol
  # estimate with headroom. OANDA's candles endpoint accepts `count`
  # directly so no date arithmetic is needed.
  @bars_per_pair 90

  # Annualised vol ceiling for M-007. Above 10% the carry risk premium
  # is typically consumed by gap risk during unwinding events.
  @m007_max_ann_vol 10.0

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    method = args["method"] || "all"

    case resolve_oanda_org(args["org_id"]) do
      {:ok, org_id} ->
        Logger.info("MethodBacktestWorker: running method=#{method} via org #{org_id}")

        if method in ["all", "m007"] do
          run_m007(org_id)
        end

        :ok

      {:error, :no_oanda_org} ->
        Logger.info(
          "MethodBacktestWorker: no org with OANDA credentials found — " <>
            "skipping (method backtests require OANDA practice creds for carry data)"
        )

        :ok
    end
  end

  # ── M-007 ─────────────────────────────────────────────────────────────────────

  defp run_m007(org_id) do
    results =
      Enum.map(@m007_carry_pairs, fn pair ->
        case fetch_carry_bars(org_id, pair) do
          {:ok, [_ | _] = bars} ->
            case MethodSeeder.m007_conditions_met?(bars, max_ann_vol: @m007_max_ann_vol) do
              true ->
                Logger.info("MethodBacktestWorker M-007: #{pair} — carry conditions MET, seeding")

                inserted =
                  bars
                  |> MethodSeeder.insights_for_m007(
                    symbol: pair,
                    platform: "oanda_practice",
                    timeframe: "1Day",
                    max_ann_vol: @m007_max_ann_vol
                  )
                  |> upsert_all()

                {:ok, pair, inserted}

              false ->
                Logger.info(
                  "MethodBacktestWorker M-007: #{pair} — carry conditions NOT met " <>
                    "(realised vol above #{@m007_max_ann_vol}%), skipping"
                )

                {:skip, pair, 0}
            end

          {:ok, []} ->
            Logger.warning("MethodBacktestWorker M-007: #{pair} — no bars returned")
            {:skip, pair, 0}

          {:error, reason} ->
            Logger.warning(
              "MethodBacktestWorker M-007: #{pair} — candle fetch failed: #{inspect(reason)}"
            )

            {:skip, pair, 0}
        end
      end)

    seeded = results |> Enum.filter(&match?({:ok, _, _}, &1)) |> length()
    total = results |> Enum.map(fn {_, _, n} -> n end) |> Enum.sum()

    Logger.info(
      "MethodBacktestWorker M-007: #{seeded}/#{length(@m007_carry_pairs)} pairs seeded, " <>
        "#{total} insights inserted (seed=#{MethodSeeder.seed_version()})"
    )
  end

  defp fetch_carry_bars(org_id, pair) do
    candles = Oanda.candles(org_id, pair, "D", @bars_per_pair, :practice, "M")

    case candles do
      list when is_list(list) and list != [] -> {:ok, list}
      [] -> {:ok, []}
      _ -> {:error, :no_data}
    end
  end

  defp upsert_all(attrs_list) do
    Enum.reduce(attrs_list, 0, fn attrs, count ->
      case CollectiveIntelligence.record_synthetic_outcome(attrs) do
        :ok -> count + 1
        _ -> count
      end
    end)
  end

  # ── Credential resolution ─────────────────────────────────────────────────────

  # Find the first org that has OANDA practice credentials configured.
  # This mirrors the Alpaca-credential lookup in KciSeederWorker but
  # targets the "oanda" provider instead of "alpaca".
  defp resolve_oanda_org(nil) do
    case Repo.one(
           from c in ApiCredential,
             where: c.provider == "oanda",
             order_by: [asc: c.inserted_at],
             limit: 1,
             select: c.org_id
         ) do
      nil -> {:error, :no_oanda_org}
      org_id -> {:ok, org_id}
    end
  end

  defp resolve_oanda_org(org_id) when is_binary(org_id), do: {:ok, org_id}
end
