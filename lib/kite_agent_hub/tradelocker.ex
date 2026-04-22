defmodule KiteAgentHub.TradeLocker do
  @moduledoc """
  Context for TradeLocker (forex) integration.

  Orchestrates credential decryption → JWT exchange → REST reads. The
  decrypted password lives only in a single authenticate/1 call frame
  and is never persisted in plaintext, cached, or logged. The JWT is
  ephemeral and returned to the caller; we do not cache it in the DB.
  """

  require Logger

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.TradingPlatforms.TradeLockerClient

  @doc """
  Does this agent have permission to act on TradeLocker?
  Trading agents only; research/conversational get view-only.
  """
  def can_trade?(nil), do: false
  def can_trade?(%{agent_type: "trading"}), do: true
  def can_trade?(_), do: false

  @doc """
  Connect using the org's stored TradeLocker credentials and run `fun`
  with {access_token, account_id}. The password is decrypted in-process
  only for the JWT exchange, never logged. Returns whatever `fun`
  returns, or `{:error, reason}` if credentials / auth fail.
  """
  def with_session(org_id, fun) when is_function(fun, 2) do
    with {:ok, cred} <- fetch_credential(org_id),
         {:ok, %{access: access}} <-
           TradeLockerClient.authenticate(cred.key_id, cred.password, cred.server) do
      fun.(access, cred.account_id)
    else
      {:error, _} = err -> err
      _ -> {:error, :unknown}
    end
  rescue
    e ->
      Logger.error("TradeLocker.with_session crashed: #{inspect(e)}")
      {:error, :exception}
  end

  @doc "List positions for an org. Returns [] on any failure."
  def list_positions(org_id) do
    case with_session(org_id, fn access, account_id ->
           TradeLockerClient.list_positions(access, account_id)
         end) do
      {:ok, positions} when is_list(positions) -> positions
      {:ok, %{"d" => %{"positions" => list}}} when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "List instruments for an org. Returns [] on any failure."
  def list_instruments(org_id) do
    case with_session(org_id, fn access, account_id ->
           TradeLockerClient.list_instruments(access, account_id)
         end) do
      {:ok, instruments} when is_list(instruments) -> instruments
      {:ok, %{"d" => %{"instruments" => list}}} when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  # Pull the stored TradeLocker credential for the org and decrypt the
  # password into a one-off map. Caller is responsible for not storing
  # the returned password anywhere.
  defp fetch_credential(org_id) do
    case Credentials.get_credential(org_id, "tradelocker") do
      nil ->
        {:error, :not_configured}

      cred ->
        case Credentials.fetch_secret(org_id, :tradelocker) do
          {:ok, {email, password}} ->
            {:ok,
             %{
               key_id: email,
               password: password,
               server: cred.server || "PRDTL",
               account_id: cred.account_id
             }}

          err ->
            err
        end
    end
  end
end
