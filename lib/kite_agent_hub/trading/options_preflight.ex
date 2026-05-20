defmodule KiteAgentHub.Trading.OptionsPreflight do
  @moduledoc """
  Pure preflight for an Alpaca options trade intent.

  Returns `{:ok, intent}` on a valid intent (with normalized fields) or
  `{:error, reason, details}` where `reason` is a stable atom and
  `details` is a small map the caller can surface in a friendly error.

  Source of truth for the order-body shape:
  https://docs.alpaca.markets/us/docs/options-orders

  G.2a constraints (no worker wiring yet — this module is exercised by
  `AlpacaClient.place_options_order/4` and by hermetic tests):

    * **OCC-only symbols.** Anything that does not match the OCC layout
      is rejected before a broker round-trip.
    * **Calls and puts only.** Other contract types (no exotic shapes
      exist in Alpaca's surface, but we still gate explicitly) are
      rejected at the boundary.
    * **Side ∈ {"buy", "sell"}.** Per the docs above, the
      `/v2/orders` POST takes `side: "buy" | "sell"` for options — the
      open/close intent is *implied through side values* by Alpaca
      (e.g. a `sell` against an existing long position closes it).
      Paper accounts default to Level-1 (long calls / puts only); a
      `sell` without an existing long open will 403 at the broker as a
      naked-short attempt. Multi-leg + spreads are Level-3 + live only
      (https://docs.alpaca.markets/us/docs/options-level-3-trading) and
      out of scope here.
    * **Positive integer contract qty.** Alpaca rejects fractional
      contracts with a 422; defensive guard returns `:non_positive_qty`
      or `:non_integer_qty` instead of letting it through.
    * **Notional cap.** `qty * limit_price * 100` (contract multiplier)
      must fit under the supplied `notional_cap_usd` (defaults to the
      operator-set `$5,000` per-trade ceiling from
      `KiteAgentHub.Trading.Risk`). Limit price is required because a
      bare-market options order cannot be sized for the cap until the
      broker fills it; the worker dispatch (G.2b) carries this through.
    * **Premium guardrail.** When `max_premium_per_contract` is
      supplied, an order whose `limit_price` exceeds `2x` that figure
      is rejected with `:premium_over_guardrail` so an IV-bloat spike
      cannot blow the notional cap in the gap between agent scoring
      and broker fill.

  This module is intentionally side-effect-free: no HTTP, no DB, no
  logging. The worker dispatch in PR-G.2b will compose it with the
  market-hours gate, the user-configured-risk policy resolution, and
  the broker call.
  """

  alias KiteAgentHub.Trading.OccSymbol
  alias KiteAgentHub.Trading.Risk

  @contract_multiplier 100

  @type intent :: %{
          required(:symbol) => String.t(),
          required(:qty) => pos_integer(),
          required(:side) => String.t(),
          optional(:limit_price) => number(),
          optional(:option_type) => atom() | String.t(),
          optional(any()) => any()
        }

  @type opts :: [
          notional_cap_usd: Decimal.t() | number(),
          max_premium_per_contract: number() | nil,
          underlying_allow_list: [String.t()] | nil
        ]

  @doc """
  Validate an options trade intent. Returns `{:ok, normalized_intent}`
  on success (with a `:underlying`, `:option_type`, `:expiration_date`,
  `:strike`, and `:notional_usd` field added from the OCC parse) or
  `{:error, reason, details}` on rejection.
  """
  @spec validate(intent(), opts()) ::
          {:ok, map()} | {:error, atom(), map()}
  def validate(intent, opts \\ []) when is_map(intent) do
    with {:ok, symbol} <- fetch_symbol(intent),
         {:ok, occ} <- parse_occ(symbol),
         :ok <- assert_option_type(occ),
         :ok <- assert_side(intent),
         {:ok, qty} <- fetch_qty(intent),
         {:ok, limit_price} <- fetch_limit_price(intent),
         :ok <- assert_premium_guardrail(limit_price, opts),
         :ok <- assert_underlying_allowed(occ.root, opts),
         {:ok, notional_usd} <- compute_notional(qty, limit_price),
         :ok <- assert_under_cap(notional_usd, opts) do
      {:ok,
       intent
       |> Map.put(:underlying, occ.root)
       |> Map.put(:option_type, occ.option_type)
       |> Map.put(:expiration_date, occ.expiration_date)
       |> Map.put(:strike, occ.strike)
       |> Map.put(:notional_usd, notional_usd)
       |> Map.put(:qty, qty)
       |> Map.put(:limit_price, limit_price)
       |> Map.put(:symbol, symbol)}
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Field extraction
  # ────────────────────────────────────────────────────────────────

  defp fetch_symbol(intent) do
    case Map.get(intent, :symbol) || Map.get(intent, "symbol") do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, :missing_symbol, %{}}
    end
  end

  defp parse_occ(symbol) do
    case OccSymbol.parse(symbol) do
      {:ok, occ} -> {:ok, occ}
      :error -> {:error, :invalid_symbol, %{symbol: symbol}}
    end
  end

  defp assert_option_type(%{option_type: :call}), do: :ok
  defp assert_option_type(%{option_type: :put}), do: :ok
  defp assert_option_type(%{option_type: t}), do: {:error, :unsupported_option_type, %{option_type: t}}

  # Alpaca /v2/orders accepts side="buy" | "sell" for options; the
  # open/close intent is implied from the existing position context
  # per the docs. Anything else is a rejection at the boundary so the
  # broker never sees a malformed payload.
  defp assert_side(intent) do
    case Map.get(intent, :side) || Map.get(intent, "side") do
      side when side in ["buy", "sell"] -> :ok
      side -> {:error, :unsupported_side, %{side: side}}
    end
  end

  defp fetch_qty(intent) do
    case Map.get(intent, :qty) || Map.get(intent, "qty") do
      q when is_integer(q) and q > 0 -> {:ok, q}
      q when is_integer(q) -> {:error, :non_positive_qty, %{qty: q}}
      q when is_float(q) -> {:error, :non_integer_qty, %{qty: q}}
      _ -> {:error, :missing_qty, %{}}
    end
  end

  defp fetch_limit_price(intent) do
    case Map.get(intent, :limit_price) || Map.get(intent, "limit_price") do
      p when is_number(p) and p > 0 -> {:ok, p * 1.0}
      _ -> {:error, :missing_limit_price, %{}}
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Premium guardrail (IV-bloat auto-reject)
  # ────────────────────────────────────────────────────────────────

  defp assert_premium_guardrail(limit_price, opts) do
    case Keyword.get(opts, :max_premium_per_contract) do
      nil ->
        :ok

      cap when is_number(cap) and cap > 0 ->
        if limit_price > 2.0 * cap do
          {:error, :premium_over_guardrail,
           %{limit_price: limit_price, max_premium_per_contract: cap, ceiling: 2.0 * cap}}
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Underlying allow-list (worker layer enforces NVDA-only on paper;
  # this lets G.2b pass the list in once)
  # ────────────────────────────────────────────────────────────────

  defp assert_underlying_allowed(root, opts) do
    case Keyword.get(opts, :underlying_allow_list) do
      nil ->
        :ok

      [] ->
        :ok

      list when is_list(list) ->
        if root in list,
          do: :ok,
          else: {:error, :underlying_not_allowed, %{underlying: root, allow_list: list}}
    end
  end

  # ────────────────────────────────────────────────────────────────
  # Notional cap
  # ────────────────────────────────────────────────────────────────

  defp compute_notional(qty, limit_price) do
    {:ok, qty * limit_price * @contract_multiplier}
  end

  defp assert_under_cap(notional_usd, opts) do
    cap = resolve_cap(Keyword.get(opts, :notional_cap_usd))

    cond do
      is_nil(cap) ->
        :ok

      Decimal.compare(Decimal.from_float(notional_usd / 1.0), cap) == :gt ->
        {:error, :notional_over_cap, %{notional_usd: notional_usd, cap_usd: Decimal.to_float(cap)}}

      true ->
        :ok
    end
  end

  defp resolve_cap(nil), do: Risk.notional_ceiling_usd()
  defp resolve_cap(%Decimal{} = d), do: d
  defp resolve_cap(n) when is_integer(n), do: Decimal.new(n)
  defp resolve_cap(n) when is_float(n), do: Decimal.from_float(n)
  defp resolve_cap(_), do: nil

  @doc "The OCC contract multiplier (100 shares per contract) exposed for tests + worker."
  def contract_multiplier, do: @contract_multiplier
end
