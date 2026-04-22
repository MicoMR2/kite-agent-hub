defmodule KiteAgentHub.TradingPlatforms.TradeLockerClient do
  @moduledoc """
  TradeLocker REST client (demo server only).

  Auth model: email + password + server brand → JWT access token.
  Token is short-lived and refreshed by the caller as needed — the
  plaintext password is never re-persisted; it stays encrypted in
  ApiCredential and only decrypts long enough to exchange for a JWT.

  Base URL is hardcoded to the demo host per CyberSec condition ①.
  Live broker-specific hosts are out of scope for this module.
  """

  require Logger

  @base "https://demo.tradelocker.com/backend-api"
  @timeout 10_000

  @doc """
  Exchange email/password/server for a JWT. Returns `{:ok, %{access, refresh}}`
  or `{:error, reason}`. Never logs the password.
  """
  def authenticate(email, password, server) when is_binary(email) and is_binary(password) and is_binary(server) do
    body = %{email: email, password: password, server: server}

    case Req.post(@base <> "/auth/jwt/token",
           json: body,
           receive_timeout: @timeout,
           headers: [{"accept", "application/json"}]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"accessToken" => access} = b}} ->
        {:ok, %{access: access, refresh: Map.get(b, "refreshToken")}}

      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"accessToken" => access} = b} ->
            {:ok, %{access: access, refresh: Map.get(b, "refreshToken")}}

          _ ->
            {:error, :malformed_auth_response}
        end

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("TradeLocker auth #{status}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("TradeLocker auth transport error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "List instruments for an account. Needs a valid JWT access token."
  def list_instruments(access_token, account_id) when is_binary(access_token) and is_binary(account_id) do
    get("/trade/accounts/#{account_id}/instruments", access_token)
  end

  @doc "List open positions for an account."
  def list_positions(access_token, account_id) when is_binary(access_token) and is_binary(account_id) do
    get("/trade/accounts/#{account_id}/positions", access_token)
  end

  defp get(path, access_token) do
    case Req.get(@base <> path,
           headers: [
             {"authorization", "Bearer " <> access_token},
             {"accept", "application/json"}
           ],
           receive_timeout: @timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
