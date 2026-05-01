defmodule KiteAgentHub.Trading.OccSymbol do
  @moduledoc """
  Single source of truth for the OCC option-contract symbol format
  (Options Clearing Corporation standard).

  Layout: `<root 1-6><YYMMDD><C|P><strike8>`
    - root: 1-6 uppercase letters (e.g. AAPL, SPY, BRKB)
    - expiration: YYMMDD (e.g. 260117 for Jan 17, 2026)
    - C or P: call or put
    - strike: 8 digits — strike × 1000 (e.g. 00100000 = $100.00)

  Example: `AAPL260117C00100000` — Apple Jan 17 2026 \$100 call.

  Used by:
    - `AlpacaClient.order_body/4` to gate options-specific payload sanitization
    - `TradeExecutionWorker.detect_platform/2` to route OCC symbols to Alpaca
    - `CollectiveIntelligence.market_class/1` to bucket option trades for analytics
  """

  @regex ~r/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/

  @doc "Returns true if `symbol` is a valid OCC option contract symbol."
  @spec match?(String.t() | any()) :: boolean()
  def match?(symbol) when is_binary(symbol), do: Regex.match?(@regex, symbol)
  def match?(_), do: false

  @doc "The compiled OCC regex, exposed for callers that need it directly."
  @spec regex() :: Regex.t()
  def regex, do: @regex
end
