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
        query = URI.encode_query(%{"granularity" => granularity, "count" => clamped, "price" => "M"})

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
  def place_practice_order(token, account_id, instrument, units)
      when is_binary(token) and is_binary(account_id) and is_binary(instrument) and
             is_integer(units) do
    body = %{
      "order" => %{
        "type" => "MARKET",
        "instrument" => instrument,
        "units" => Integer.to_string(units),
        "timeInForce" => "FOK",
        "positionFill" => "DEFAULT"
      }
    }

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
