defmodule KiteAgentHub.CollectiveIntelligence.NewsSeeder do
  @moduledoc """
  Generates synthetic KCI insights from Benzinga news headlines.

  Works alongside `Seeder` (which uses price bars) but derives sentiment
  from article headlines rather than OHLCV returns. Each article produces
  up to two insight rows: one in the direction implied by the sentiment
  and its inverse, with an outcome bucket derived from the headline tone.

  Determinism: the `source_trade_hash` is keyed on
  `(seed_version, symbol, article_created_at, direction)` so re-runs
  upsert cleanly via `on_conflict: :nothing`.

  Sentiment heuristic: keyword matching against a curated positive /
  negative wordlist. Neutral headlines (no match) are skipped — they
  carry no directional signal and would only dilute the corpus with
  50/50 noise.
  """

  alias KiteAgentHub.CollectiveIntelligence

  @seed_version "news-seed-v1-2026-05"

  # Keyword lists are intentionally conservative — only words that
  # strongly imply a directional market reaction in an earnings/macro
  # context. Common words that could appear in either context ("change",
  # "moves", "up", "down") are excluded to keep the signal clean.
  @positive_words ~w(
    beat beats beating exceeded exceeds outperform outperforms upgraded upgrade
    surges surge surging rallies rally rallying rises rise rising gains gain
    record bullish strong stronger strength profit profits boom booming
    growth grows growing expansion expands breakthrough innovation
    optimistic confident confidence
  )

  @negative_words ~w(
    miss misses missed disappoints disappoint disappointing falls fall falling
    drops drop dropping declines decline declining slumps slump slumping
    downgraded downgrade warning warns warn losses loss cuts cut cutting
    weak weaker weakness bearish concern concerns feared fear
    struggles struggle struggling crisis downturn contraction
  )

  @doc """
  Parse a list of raw Alpaca/Benzinga article maps into synthetic insight
  attrs. Pure — callers insert via `CollectiveIntelligence.record_synthetic_outcome/1`.

  Each article that matches a directional sentiment produces:
  - A "long" row with `outcome_bucket = "profit"` (positive sentiment) or
    `"loss"` (negative sentiment).
  - A "short" row with the inverse outcome bucket.

  This mirrors the `Seeder.insights_from_bars/2` pattern of always
  inserting both directions so the corpus is balanced.

  ## Opts
    * `:market_class` — `"equity" | "crypto"` (required)
    * `:platform`     — `"alpaca"` (required)
    * `:notional_bucket` — default `"100_to_999"`
  """
  def insights_from_articles(articles, opts) when is_list(articles) do
    market_class = Keyword.fetch!(opts, :market_class)
    platform = Keyword.fetch!(opts, :platform)
    notional = Keyword.get(opts, :notional_bucket, "100_to_999")

    articles
    |> Enum.flat_map(fn article ->
      headline = article_text(article)
      sentiment = classify_sentiment(headline)
      symbols = article_symbols(article)
      ts = article_ts(article)

      if sentiment == :neutral or symbols == [] do
        []
      else
        Enum.flat_map(symbols, fn symbol ->
          build_rows(sentiment, symbol, ts, market_class, platform, notional)
        end)
      end
    end)
  end

  @doc "Return the seed version string. Bumped when the heuristic logic changes."
  def seed_version, do: @seed_version

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_rows(sentiment, symbol, ts, market_class, platform, notional) do
    {long_outcome, short_outcome} =
      case sentiment do
        :positive -> {"profit", "loss"}
        :negative -> {"loss", "profit"}
      end

    [
      synthetic_attrs(:long, long_outcome, symbol, ts, market_class, platform, notional),
      synthetic_attrs(:short, short_outcome, symbol, ts, market_class, platform, notional)
    ]
  end

  defp synthetic_attrs(direction, outcome, symbol, ts, market_class, platform, notional) do
    side =
      case {market_class, direction} do
        {"prediction", :long} -> "yes"
        {"prediction", :short} -> "no"
        {_, :long} -> "long"
        {_, :short} -> "short"
      end

    action = if direction == :long, do: "buy", else: "sell"

    %{
      source_trade_hash:
        CollectiveIntelligence.seed_hash(
          "synthetic",
          "#{@seed_version}|#{platform}|#{symbol}|#{ts}|#{direction}"
        ),
      source_org_hash: CollectiveIntelligence.seed_hash("seed", @seed_version),
      agent_type: "synthetic",
      platform: platform,
      market_class: market_class,
      side: side,
      action: action,
      status: "settled",
      outcome_bucket: outcome,
      notional_bucket: notional,
      # News-derived insights are always assumed intraday — the market
      # reaction to a headline typically plays out in under an hour.
      hold_time_bucket: "1h_to_1d",
      observed_week: week_of(ts)
    }
  end

  # ── Sentiment heuristic ───────────────────────────────────────────────────────

  @doc false
  def classify_sentiment(text) when is_binary(text) do
    lower = String.downcase(text)
    words = Regex.scan(~r/\b\w+\b/, lower) |> List.flatten()

    positives = Enum.count(words, &(&1 in @positive_words))
    negatives = Enum.count(words, &(&1 in @negative_words))

    cond do
      positives > negatives -> :positive
      negatives > positives -> :negative
      true -> :neutral
    end
  end

  def classify_sentiment(_), do: :neutral

  # ── Article field extraction ──────────────────────────────────────────────────

  defp article_text(article) do
    headline = article["headline"] || article[:headline] || ""
    summary = article["summary"] || article[:summary] || ""
    "#{headline} #{summary}"
  end

  defp article_symbols(article) do
    article["symbols"] || article[:symbols] || []
  end

  defp article_ts(article) do
    article["created_at"] || article["updated_at"] || article[:created_at] || nil
  end

  defp week_of(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} -> dt |> DateTime.to_date() |> Date.beginning_of_week(:monday)
      _ -> Date.utc_today() |> Date.beginning_of_week(:monday)
    end
  end

  defp week_of(_), do: Date.utc_today() |> Date.beginning_of_week(:monday)
end
