defmodule KiteAgentHub.Trading.Risk do
  @moduledoc """
  Per-agent risk policy: per-trade notional cap, profit-trim ladder,
  market-hours-only flag. Values come from `agent.risk_config` if set;
  any missing key falls through to the module-level default below.

  An invalid `risk_config` (unknown shape that survived a manual DB
  edit, or a key whose value is out of bounds) is **fail-closed** —
  callers should treat `{:error, :invalid_risk_config}` as "suspend the
  agent and surface the form" rather than silently using defaults. The
  changeset (`KiteAgent.risk_config_changeset/2`) is the only sanctioned
  write path; this module never coerces.
  """

  alias KiteAgentHub.Trading.KiteAgent

  # Defaults sourced from the operator's working memory:
  #   feedback_kah_trade_cap         — under $5K per-trade
  #   feedback_kah_quick_profits     — partial trim ≥75% on +5–8%; ladder is +3% partial / +5% full
  #   feedback_kah_market_hours      — equities/options only during US market hours
  @defaults %{
    per_trade_notional_cap_usd: Decimal.new("5000"),
    profit_trim_partial_pct: 3,
    profit_trim_full_pct: 5,
    market_hours_only: true
  }

  # Hard server ceiling — the changeset rejects user input above this.
  # Lives here so the trade-execution path can re-assert the bound at
  # runtime even if a row predates the validator.
  @notional_ceiling_usd Decimal.new("5000")

  def defaults, do: @defaults
  def notional_ceiling_usd, do: @notional_ceiling_usd

  @doc """
  Resolve the per-trade notional cap (Decimal) for an agent.

  Returns `{:ok, decimal, source}` where `source` is `:user_defined |
  :module_default`, or `{:error, :invalid_risk_config}` if the stored
  config is structurally bad. Callers MUST handle the error case —
  do not pattern-match only on `:ok`.
  """
  def per_trade_notional_cap(%KiteAgent{risk_config: cfg}) do
    case Map.get(cfg || %{}, "per_trade_notional_cap_usd") do
      nil ->
        {:ok, @defaults.per_trade_notional_cap_usd, :module_default}

      value ->
        with {:ok, decimal} <- decode_decimal(value),
             :ok <- assert_positive(decimal),
             :ok <- assert_at_or_below(decimal, @notional_ceiling_usd) do
          {:ok, decimal, :user_defined}
        else
          _ -> {:error, :invalid_risk_config}
        end
    end
  end

  @doc """
  Resolve the profit-trim ladder for an agent.

  Returns `{:ok, %{partial_pct, full_pct}, source}` or
  `{:error, :invalid_risk_config}`.
  """
  def profit_trim_ladder(%KiteAgent{risk_config: cfg}) do
    cfg = cfg || %{}
    partial_in = Map.get(cfg, "profit_trim_partial_pct")
    full_in = Map.get(cfg, "profit_trim_full_pct")

    cond do
      is_nil(partial_in) and is_nil(full_in) ->
        {:ok,
         %{
           partial_pct: @defaults.profit_trim_partial_pct,
           full_pct: @defaults.profit_trim_full_pct
         }, :module_default}

      is_integer(partial_in) and is_integer(full_in) and
        partial_in in 0..100 and full_in in 0..100 and full_in > partial_in ->
        {:ok, %{partial_pct: partial_in, full_pct: full_in}, :user_defined}

      true ->
        {:error, :invalid_risk_config}
    end
  end

  @doc "Resolve the market-hours-only flag. Defaults to true."
  def market_hours_only?(%KiteAgent{risk_config: cfg}) do
    case Map.get(cfg || %{}, "market_hours_only") do
      nil -> {:ok, @defaults.market_hours_only, :module_default}
      v when is_boolean(v) -> {:ok, v, :user_defined}
      _ -> {:error, :invalid_risk_config}
    end
  end

  defp decode_decimal(%Decimal{} = d), do: {:ok, d}

  defp decode_decimal(v) when is_binary(v) or is_integer(v) do
    {:ok, Decimal.new(to_string(v))}
  rescue
    _ -> :error
  end

  defp decode_decimal(_), do: :error

  defp assert_positive(%Decimal{} = d) do
    if Decimal.compare(d, Decimal.new(0)) == :gt, do: :ok, else: :error
  end

  defp assert_at_or_below(%Decimal{} = d, %Decimal{} = ceiling) do
    if Decimal.compare(d, ceiling) in [:lt, :eq], do: :ok, else: :error
  end
end
