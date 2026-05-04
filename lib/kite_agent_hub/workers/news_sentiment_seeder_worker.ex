defmodule KiteAgentHub.Workers.NewsSentimentSeederWorker do
  @moduledoc """
  Seeds the KCI corpus with synthetic trade outcomes derived from
  Benzinga news headlines pulled via `EquityOracle.news/2`.

  Flow:
  1. Resolve an org with Alpaca credentials (same logic as KciSeederWorker).
  2. Fetch the last N days of news for the seed symbols.
  3. Pass each article to `NewsSeeder.insights_from_articles/2` which
     classifies the headline sentiment and emits both a long and short
     insight row.
  4. Upsert into the KCI corpus via
     `CollectiveIntelligence.record_synthetic_outcome/1` — idempotent on
     `source_trade_hash` so reruns are safe.

  The cron schedule (see `config/config.exs`) runs this daily — news
  sentiment is more volatile than price bars so a shorter cadence
  keeps the corpus fresh.

  Manual trigger from iex:

      KiteAgentHub.Workers.NewsSentimentSeederWorker.new(%{}) |> Oban.insert()
      # Or target a specific org:
      KiteAgentHub.Workers.NewsSentimentSeederWorker.new(%{"org_id" => "..."}) |> Oban.insert()
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  require Logger

  alias KiteAgentHub.{CollectiveIntelligence, EquityOracle, Repo}
  alias KiteAgentHub.CollectiveIntelligence.NewsSeeder
  alias KiteAgentHub.Credentials.ApiCredential

  import Ecto.Query

  # Symbols to fetch news for. Kept to the high-liquidity names where
  # Benzinga article volume is meaningful. Crypto symbols are omitted —
  # Alpaca's news endpoint covers equity tickers only.
  @seed_symbols ~w(SPY QQQ AAPL MSFT NVDA AMZN GOOGL META TSLA AMD)

  # Fetch up to 7 days back; Alpaca's news endpoint defaults to most
  # recent when no start is given so we set an explicit start to ensure
  # a consistent window. 50 articles per call is the API maximum.
  @look_back_days 7
  @articles_per_call 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case resolve_org(args["org_id"]) do
      {:ok, org_id} ->
        Logger.info("NewsSentimentSeederWorker: seeding news sentiment via org #{org_id}")
        run(org_id)

      {:error, :no_alpaca_org} ->
        Logger.info(
          "NewsSentimentSeederWorker: no org with Alpaca credentials found — skipping"
        )

        :ok
    end
  end

  defp run(org_id) do
    start_iso = start_date_iso()

    opts = [
      symbols: @seed_symbols,
      start: start_iso,
      limit: @articles_per_call,
      sort: "desc",
      exclude_contentless: true
    ]

    case EquityOracle.news(org_id, opts) do
      {:ok, articles} when is_list(articles) ->
        inserted = seed_articles(articles)

        Logger.info(
          "NewsSentimentSeederWorker: inserted #{inserted} news-sentiment insights " <>
            "(#{length(articles)} articles, seed=#{NewsSeeder.seed_version()})"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "NewsSentimentSeederWorker: news fetch failed — #{inspect(reason)}, skipping"
        )

        :ok
    end
  end

  defp seed_articles(articles) do
    attrs_list =
      NewsSeeder.insights_from_articles(articles,
        market_class: "equity",
        platform: "alpaca"
      )

    Enum.reduce(attrs_list, 0, fn attrs, count ->
      case CollectiveIntelligence.record_synthetic_outcome(attrs) do
        :ok -> count + 1
        _ -> count
      end
    end)
  end

  # ISO-8601 date string for `look_back_days` ago. Alpaca's news endpoint
  # accepts RFC 3339 — midnight UTC is fine for a daily seeder.
  defp start_date_iso do
    Date.utc_today()
    |> Date.add(-@look_back_days)
    |> Date.to_iso8601()
    |> Kernel.<>("T00:00:00Z")
  end

  # Identical credential resolution strategy to KciSeederWorker.
  # Picks the earliest org with an Alpaca credential row so we share
  # the same org for all seeding jobs without coupling the workers.
  defp resolve_org(nil) do
    case Repo.one(
           from c in ApiCredential,
             where: c.provider == "alpaca",
             order_by: [asc: c.inserted_at],
             limit: 1,
             select: c.org_id
         ) do
      nil -> {:error, :no_alpaca_org}
      org_id -> {:ok, org_id}
    end
  end

  defp resolve_org(org_id) when is_binary(org_id), do: {:ok, org_id}
end
