defmodule KiteAgentHub.TradingPlatforms.OandaClient do
  @moduledoc """
  OANDA v20 REST client. Supports both practice (demo) and live
  environments. Base URLs are compile-time constants — callers never
  supply an arbitrary host (CyberSec ①).

  Auth: `Authorization: Bearer {token}` on every call. The token is
  never logged; only HTTP status codes and transport error reasons
  hit the logger.
  """

  require Logger

  @base_practice "https://api-fxpractice.oanda.com/v3"
  @base_live "https://api-fxtrade.oanda.com/v3"
  @timeout 10_000

  @doc """
  Pick a base URL from an env atom. Only the two hardcoded bases are
  ever used — no caller-supplied host.
  """
  def base_url(:live), do: @base_live
  def base_url(_), do: @base_practice

  @doc "GET /v3/accounts/{id}/summary — balance, NAV, margin."
  def account_summary(token, account_id, env \\ :practice),
    do: get("/accounts/#{account_id}/summary", token, env)

  @doc "GET /v3/accounts/{id}/instruments — tradeable pairs."
  def list_instruments(token, account_id, env \\ :practice),
    do: get("/accounts/#{account_id}/instruments", token, env)

  @doc "GET /v3/accounts/{id}/openPositions — open positions."
  def list_open_positions(token, account_id, env \\ :practice),
    do: get("/accounts/#{account_id}/openPositions", token, env)

  @doc "GET /v3/accounts/{id}/pricing?instruments=EUR_USD,GBP_USD — live bid/ask."
  def pricing(token, account_id, instruments, env \\ :practice) when is_list(instruments) do
    query = URI.encode_query(%{"instruments" => Enum.join(instruments, ",")})
    get("/accounts/#{account_id}/pricing?" <> query, token, env)
  end

  @valid_granularities ~w(M1 M5 M15 M30 H1 H4 D)

  @doc """
  GET /v3/instruments/{name}/candles — OHLC candles for chart rendering.

  `instrument` must match the OANDA symbol convention (e.g. EUR_USD);
  validated against a strict regex before URL interpolation to prevent
  path traversal. `granularity` must be one of `@valid_granularities`
  (M1..D). `count` is clamped to 1..500.
  """
  def candles(token, instrument, granularity \\ "M5", count \\ 120, env \\ :practice)
      when is_binary(token) and is_binary(instrument) do
    cond do
      not valid_instrument?(instrument) ->
        {:error, :invalid_instrument}

      granularity not in @valid_granularities ->
        {:error, :invalid_granularity}

      true ->
        clamped = count |> max(1) |> min(500)

        query =
          URI.encode_query(%{"granularity" => granularity, "count" => clamped, "price" => "M"})

        get("/instruments/" <> instrument <> "/candles?" <> query, token, env)
    end
  end

  defp valid_instrument?(s) when is_binary(s), do: Regex.match?(~r/^[A-Z]{2,8}_[A-Z]{2,8}$/, s)
  defp valid_instrument?(_), do: false

  @doc """
  POST /v3/accounts/{id}/orders — place a market order on the PRACTICE
  endpoint only. Signed units: positive for buy, negative for sell per
  OANDA v20 spec. Hardcoded to the practice base — live orders are
  intentionally unimplemented here (requires its own security review).
  """
  def place_practice_order(token, account_id, instrument, units, opts \\ %{})
      when is_binary(token) and is_binary(account_id) and is_binary(instrument) and
             is_integer(units) do
    body = practice_order_body(instrument, units, opts)

    case Req.post(@base_practice <> "/accounts/#{account_id}/orders",
           json: body,
           headers: [
             {"authorization", "Bearer " <> token},
             {"accept", "application/json"}
           ],
           receive_timeout: @timeout
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..201 ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("OANDA practice order #{status} on /accounts/#{account_id}/orders")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("OANDA practice order transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def practice_order_body(instrument, units, opts \\ %{}) do
    opts = normalize_opts(opts)
    order_type = normalize_order_type(opts["order_type"] || opts["type"] || "MARKET")

    order =
      %{
        "type" => order_type,
        "instrument" => instrument,
        "units" => Integer.to_string(units),
        "timeInForce" =>
          normalize_time_in_force(opts["time_in_force"] || opts["timeInForce"], order_type),
        "positionFill" => normalize_position_fill(opts["position_fill"] || opts["positionFill"])
      }
      |> put_optional("price", opts["price"] || opts["limit_price"])
      |> put_optional("priceBound", opts["price_bound"])
      |> put_optional("gtdTime", opts["gtd_time"])
      |> put_optional("triggerCondition", normalize_upper(opts["trigger_condition"]))
      |> put_optional("clientExtensions", client_extensions(opts["client_extensions"], opts))
      |> put_optional("tradeClientExtensions", stringify_map(opts["trade_client_extensions"]))
      |> put_optional(
        "takeProfitOnFill",
        price_details(opts["take_profit"], opts["take_profit_price"])
      )
      |> put_optional(
        "stopLossOnFill",
        price_details(opts["stop_loss"], opts["stop_loss_price"])
      )
      |> put_optional(
        "trailingStopLossOnFill",
        trailing_details(opts["trailing_stop_loss"], opts["trailing_stop_distance"])
      )

    %{"order" => order}
  end

  defp normalize_order_type(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_order_type(value), do: value |> to_string() |> String.upcase()

  defp normalize_time_in_force(nil, "MARKET"), do: "FOK"
  defp normalize_time_in_force(nil, _order_type), do: "GTC"
  defp normalize_time_in_force(value, _order_type), do: normalize_upper(value)

  defp normalize_position_fill(nil), do: "DEFAULT"
  defp normalize_position_fill(value), do: normalize_upper(value)

  defp normalize_upper(nil), do: nil
  defp normalize_upper(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp normalize_upper(value), do: value |> to_string() |> String.upcase()

  defp price_details(details, price)

  defp price_details(details, _price) when is_map(details),
    do: stringify_map(details)

  defp price_details(_details, nil), do: nil

  defp price_details(_details, price), do: %{"price" => to_string(price), "timeInForce" => "GTC"}

  defp trailing_details(details, _distance) when is_map(details), do: stringify_map(details)
  defp trailing_details(_details, nil), do: nil

  defp trailing_details(_details, distance),
    do: %{"distance" => to_string(distance), "timeInForce" => "GTC"}

  defp client_extensions(extensions, _opts) when is_map(extensions), do: stringify_map(extensions)

  defp client_extensions(_extensions, opts) do
    %{}
    |> put_optional("id", opts["client_order_id"])
    |> put_optional("tag", opts["client_tag"])
    |> put_optional("comment", opts["client_comment"])
    |> case do
      map when map == %{} -> nil
      map -> map
    end
  end

  defp normalize_opts(opts) when is_map(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp normalize_opts(opts) when is_list(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp normalize_opts(_opts), do: %{}

  defp stringify_map(nil), do: nil

  defp stringify_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_map(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp get(path, token, env) do
    case Req.get(base_url(env) <> path,
           headers: [
             {"authorization", "Bearer " <> token},
             {"accept", "application/json"}
           ],
           receive_timeout: @timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("OANDA #{env} #{status} on #{path}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("OANDA #{env} transport error on #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
