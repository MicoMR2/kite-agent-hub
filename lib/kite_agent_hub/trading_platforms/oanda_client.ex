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
