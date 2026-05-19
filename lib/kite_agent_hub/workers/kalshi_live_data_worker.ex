defmodule KiteAgentHub.Workers.KalshiLiveDataWorker do
  @moduledoc """
  Periodically refreshes the `KalshiLiveDataCache` for tickers that
  have open KAH positions. Runs every minute via `:maintenance`
  queue + Oban cron. Phase 2 `KalshiEdgeScorer` reads from the
  cache rather than calling Kalshi inline — keeps the scoring path
  fast and bounded.

  Scope is intentionally tight: live-data is ephemeral (TTL 30s
  in the cache), so failed fetches just mean the next tick tries
  again. Genuine errors log + skip the ticker; the worker never
  blocks on a single bad market.
  """

  # `unique` window prevents duplicate jobs from piling up if a
  # perform overlaps the next self-scheduled run. 20s < the 25s
  # self-schedule interval below + the 60s cron tick, so dupes
  # within a single refresh cycle are de-duped.
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 2,
    unique: [period: 20, fields: [:worker, :args]]

  require Logger

  alias KiteAgentHub.{Credentials, Trading}
  alias KiteAgentHub.Kite.KalshiLiveDataCache
  alias KiteAgentHub.TradingPlatforms.KalshiClient

  # CyberSec ③ msg 10760 + Phorari 10761: 30s cache TTL paired with
  # 60s cron leaves a stale-then-empty gap. Self-schedule a follow-up
  # at +25s on every successful run so the effective refresh cadence
  # is ~25s — below the 30s TTL, no gap.
  @self_schedule_seconds 25

  @impl Oban.Worker
  def perform(_job) do
    trades = Trading.list_open_kalshi_trades_for_reconcile(older_than_seconds: 0)
    tickers_by_org = group_tickers_by_org(trades)

    {refreshed, errors} =
      Enum.reduce(tickers_by_org, {0, 0}, fn {org_id, tickers}, {r, e} ->
        case refresh_org_tickers(org_id, tickers) do
          {:ok, n} -> {r + n, e}
          {:error, _} -> {r, e + 1}
        end
      end)

    Logger.info(
      "KalshiLiveDataWorker sweep: orgs=#{map_size(tickers_by_org)} refreshed=#{refreshed} errors=#{errors}"
    )

    schedule_next()
    :ok
  end

  defp schedule_next do
    # Insert the next run; if Oban's `unique` already has a job
    # within the 20s window the conflict is silently a no-op
    # (returns `{:ok, job}` with the existing job).
    __MODULE__.new(%{}, schedule_in: @self_schedule_seconds)
    |> Oban.insert()
  end

  @doc false
  # Pure helper — exported for hermetic tests. Groups a list of
  # `%TradeRecord{}` (with `:kite_agent` preloaded) by their org id,
  # uniq'd by ticker. Returns `%{org_id => [ticker]}`.
  def group_tickers_by_org(trades) do
    trades
    |> Enum.filter(fn t -> t.kite_agent && t.kite_agent.organization_id end)
    |> Enum.group_by(
      fn t -> t.kite_agent.organization_id end,
      fn t -> t.market end
    )
    |> Map.new(fn {org, tickers} -> {org, Enum.uniq(tickers)} end)
  end

  defp refresh_org_tickers(org_id, tickers) do
    with {:ok, {key_id, pem, env}} <- Credentials.fetch_secret_with_env(org_id, :kalshi),
         {:ok, by_ticker} <- KalshiClient.multiple_live_data(key_id, pem, tickers, env) do
      Enum.each(by_ticker, fn {ticker, parsed} ->
        KalshiLiveDataCache.put(ticker, parsed)
      end)

      {:ok, map_size(by_ticker)}
    else
      err ->
        # CyberSec ⑥ msg 10760 / 10671②: log org + reason atom only.
        # KalshiClient pre-sanitizes errors but the prior `inspect(err)`
        # format drifted from the standard log surface.
        Logger.warning(
          "KalshiLiveDataWorker refresh failed org=#{org_id} reason=#{reason_atom(err)}"
        )

        err
    end
  end

  defp reason_atom({:error, reason}) when is_atom(reason), do: reason
  defp reason_atom({:error, _reason}), do: :refresh_failed
  defp reason_atom(:error), do: :refresh_failed
  defp reason_atom(_), do: :unknown
end
