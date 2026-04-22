defmodule KiteAgentHub.Oanda do
  @moduledoc """
  Context for OANDA (forex) integration. Practice environment only.

  The API token is decrypted only at call time and never persisted
  outside the encrypted credential row. Bearer auth uses the decrypted
  token for a single request and then drops it.
  """

  require Logger

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.TradingPlatforms.OandaClient

  @doc "Trading-agent gate. Non-trading agents cannot place orders."
  def can_trade?(nil), do: false
  def can_trade?(%{agent_type: "trading"}), do: true
  def can_trade?(_), do: false

  @doc "Is OANDA configured for this org?"
  def configured?(org_id) do
    case Credentials.get_credential(org_id, "oanda") do
      nil -> false
      _ -> true
    end
  end

  @doc "List open positions for the configured OANDA account. Returns [] on any failure."
  def list_positions(org_id) do
    with_token(org_id, fn token, account_id ->
      case OandaClient.list_open_positions(token, account_id) do
        {:ok, %{"positions" => positions}} when is_list(positions) -> positions
        _ -> []
      end
    end)
  end

  @doc "List instruments for the configured OANDA account. Returns [] on any failure."
  def list_instruments(org_id) do
    with_token(org_id, fn token, account_id ->
      case OandaClient.list_instruments(token, account_id) do
        {:ok, %{"instruments" => instruments}} when is_list(instruments) -> instruments
        _ -> []
      end
    end)
  end

  # Run `fun.(token, account_id)` with a decrypted token scoped to one
  # request. All failure modes (missing creds, decrypt error, raised
  # exception) collapse to [] so callers never get surprised.
  defp with_token(org_id, fun) when is_function(fun, 2) do
    try do
      case Credentials.fetch_secret(org_id, :oanda) do
        {:ok, {_label, token}} ->
          account_id =
            case Credentials.get_credential(org_id, "oanda") do
              %{account_id: id} when is_binary(id) -> id
              _ -> nil
            end

          if is_binary(account_id), do: fun.(token, account_id), else: []

        _ ->
          []
      end
    rescue
      e ->
        Logger.error("Oanda.with_token crashed: #{inspect(e)}")
        []
    end
  end
end
