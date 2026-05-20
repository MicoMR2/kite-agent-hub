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

  @doc """
  Parse an OCC option contract symbol into its component fields.

  Returns `{:ok, %{root, expiration_date, option_type, strike}}` on a valid
  OCC string, or `:error` otherwise.

    * `root`            — underlying ticker (1-6 uppercase letters)
    * `expiration_date` — `%Date{}` from the embedded YYMMDD
    * `option_type`     — `:call` or `:put`
    * `strike`          — strike price in dollars (float, embedded 8-digit
      strike × 1000)

  ## Examples

      iex> OccSymbol.parse("AAPL260117C00100000")
      {:ok, %{root: "AAPL", expiration_date: ~D[2026-01-17], option_type: :call, strike: 100.0}}

      iex> OccSymbol.parse("not-an-occ")
      :error
  """
  @spec parse(String.t() | any()) ::
          {:ok, %{root: String.t(), expiration_date: Date.t(), option_type: :call | :put, strike: float()}}
          | :error
  def parse(symbol) when is_binary(symbol) do
    if match?(symbol) do
      do_parse(symbol)
    else
      :error
    end
  end

  def parse(_), do: :error

  defp do_parse(symbol) do
    # The OCC layout is fixed-width once the root has been stripped.
    # Walk back from the right edge so a variable-length root doesn't
    # require a regex capture.
    len = byte_size(symbol)
    strike_str = binary_part(symbol, len - 8, 8)
    type_str = binary_part(symbol, len - 9, 1)
    date_str = binary_part(symbol, len - 15, 6)
    root = binary_part(symbol, 0, len - 15)

    with {strike_int, ""} <- Integer.parse(strike_str),
         {:ok, date} <- parse_date(date_str),
         {:ok, option_type} <- parse_option_type(type_str) do
      {:ok,
       %{
         root: root,
         expiration_date: date,
         option_type: option_type,
         strike: strike_int / 1000.0
       }}
    else
      _ -> :error
    end
  end

  defp parse_date(<<yy::binary-size(2), mm::binary-size(2), dd::binary-size(2)>>) do
    with {y, ""} <- Integer.parse(yy),
         {m, ""} <- Integer.parse(mm),
         {d, ""} <- Integer.parse(dd),
         {:ok, date} <- Date.new(2000 + y, m, d) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp parse_option_type("C"), do: {:ok, :call}
  defp parse_option_type("P"), do: {:ok, :put}
  defp parse_option_type(_), do: :error
end
