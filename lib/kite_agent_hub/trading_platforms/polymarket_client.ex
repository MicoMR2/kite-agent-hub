defmodule KiteAgentHub.TradingPlatforms.PolymarketClient do
  @moduledoc """
  Polymarket Gamma API client (read-only, no auth).

  Gamma is Polymarket's public market discovery API. This client only
  reads market metadata and pricing — no orders are placed here. Order
  execution will live in a separate module once the paper/live flag
  routing lands.
  """

  require Logger

  @gamma_base "https://gamma-api.polymarket.com"
  @timeout 8_000

  @doc """
  List active markets, most recently updated first.

  Returns `{:ok, [market_map]}` or `{:error, reason}`. Callers should
  wrap in their own try/rescue anyway — this module already swallows
  transport errors into `{:error, _}` but not raises from decoding.
  """
  def list_markets(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    active = Keyword.get(opts, :active, true)

    query =
      URI.encode_query(%{
        "limit" => limit,
        "active" => active,
        "closed" => false,
        "order" => "volume24hr",
        "ascending" => false
      })

    case get("/markets?" <> query) do
      {:ok, markets} when is_list(markets) -> {:ok, markets}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @doc "Fetch a single market by its slug or id."
  def get_market(id_or_slug) when is_binary(id_or_slug) do
    case get("/markets/" <> URI.encode(id_or_slug)) do
      {:ok, market} when is_map(market) -> {:ok, market}
      {:ok, _} -> {:error, :not_found}
      err -> err
    end
  end

  @doc """
  Extract a displayable yes/no pair of prices from a Gamma market.
  Gamma returns `outcomes` and `outcomePrices` as JSON-encoded strings
  in some responses — normalize into a `%{"yes" => price, "no" => price}`
  map. Missing or malformed data returns `%{}`.
  """
  def extract_prices(%{} = market) do
    with {:ok, outcomes} <- decode_list(Map.get(market, "outcomes")),
         {:ok, prices} <- decode_list(Map.get(market, "outcomePrices")) do
      outcomes
      |> Enum.zip(prices)
      |> Enum.into(%{}, fn {outcome, price} ->
        {String.downcase(to_string(outcome)), to_float(price)}
      end)
    else
      _ -> %{}
    end
  end

  def extract_prices(_), do: %{}

  defp decode_list(value) when is_list(value), do: {:ok, value}

  defp decode_list(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp decode_list(_), do: :error

  defp to_float(n) when is_number(n), do: n / 1

  defp to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp get(path) do
    url = @gamma_base <> path

    case Req.get(url, receive_timeout: @timeout, headers: [{"accept", "application/json"}]) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) or is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Polymarket Gamma #{status}: #{inspect(body) |> String.slice(0, 200)}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("Polymarket Gamma transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
