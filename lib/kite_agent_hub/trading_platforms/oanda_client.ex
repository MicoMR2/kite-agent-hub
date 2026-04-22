defmodule KiteAgentHub.TradingPlatforms.OandaClient do
  @moduledoc """
  OANDA v20 REST client (practice environment only).

  Auth: `Authorization: Bearer {token}` on every call. The token is
  never logged; only HTTP status codes and transport error reasons
  hit the logger.
  """

  require Logger

  @base "https://api-fxpractice.oanda.com/v3"
  @timeout 10_000

  @doc "GET /v3/accounts/{id}/summary — balance, NAV, margin."
  def account_summary(token, account_id), do: get("/accounts/#{account_id}/summary", token)

  @doc "GET /v3/accounts/{id}/instruments — tradeable pairs."
  def list_instruments(token, account_id), do: get("/accounts/#{account_id}/instruments", token)

  @doc "GET /v3/accounts/{id}/openPositions — open positions."
  def list_open_positions(token, account_id),
    do: get("/accounts/#{account_id}/openPositions", token)

  @doc "GET /v3/accounts/{id}/pricing?instruments=EUR_USD,GBP_USD — live bid/ask."
  def pricing(token, account_id, instruments) when is_list(instruments) do
    query = URI.encode_query(%{"instruments" => Enum.join(instruments, ",")})
    get("/accounts/#{account_id}/pricing?" <> query, token)
  end

  defp get(path, token) do
    case Req.get(@base <> path,
           headers: [
             {"authorization", "Bearer " <> token},
             {"accept", "application/json"}
           ],
           receive_timeout: @timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("OANDA #{status} on #{path}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("OANDA transport error on #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
