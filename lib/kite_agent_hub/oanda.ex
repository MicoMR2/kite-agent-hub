defmodule KiteAgentHub.Oanda do
  @moduledoc """
  Context for OANDA (forex) integration — supports both practice and
  live accounts as independent credential rows.

  Provider strings:
    * `"oanda"`       — practice / paper (api-fxpractice.oanda.com)
    * `"oanda_live"`  — real money      (api-fxtrade.oanda.com)

  The token is decrypted only at call time and never persisted outside
  the encrypted credential row. Bearer auth uses the decrypted token
  for a single request and then drops it.
  """

  require Logger

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.TradingPlatforms.OandaClient

  @type env :: :practice | :live

  @doc "Trading-agent gate. Non-trading agents cannot place orders."
  def can_trade?(nil), do: false
  def can_trade?(%{agent_type: "trading"}), do: true
  def can_trade?(_), do: false

  @doc "Is either OANDA account configured for this org?"
  def configured?(org_id) do
    configured?(org_id, :practice) or configured?(org_id, :live)
  end

  @doc "Is a specific env (practice | live) configured for this org?"
  def configured?(org_id, env) do
    case Credentials.get_credential(org_id, provider_for(env)) do
      nil -> false
      _ -> true
    end
  end

  @doc "Pick the env to use for this org. Prefer live if configured, else practice."
  def active_env(org_id) do
    cond do
      configured?(org_id, :live) -> :live
      configured?(org_id, :practice) -> :practice
      true -> nil
    end
  end

  @doc "List open positions for the given env. Returns [] on any failure."
  def list_positions(org_id, env \\ :practice) do
    with_token(org_id, env, fn token, account_id ->
      case OandaClient.list_open_positions(token, account_id, env) do
        {:ok, %{"positions" => positions}} when is_list(positions) -> positions
        _ -> []
      end
    end)
  end

  @doc "List instruments for the given env. Returns [] on any failure."
  def list_instruments(org_id, env \\ :practice) do
    with_token(org_id, env, fn token, account_id ->
      case OandaClient.list_instruments(token, account_id, env) do
        {:ok, %{"instruments" => instruments}} when is_list(instruments) -> instruments
        _ -> []
      end
    end)
  end

  # Run `fun.(token, account_id)` with a decrypted token scoped to a
  # single request. All failure modes (missing creds, decrypt error,
  # raised exception) collapse to [] so callers never get surprised.
  defp with_token(org_id, env, fun) when is_function(fun, 2) do
    provider = provider_for(env)

    try do
      case Credentials.fetch_secret(org_id, String.to_atom(provider)) do
        {:ok, {_label, token}} ->
          account_id =
            case Credentials.get_credential(org_id, provider) do
              %{account_id: id} when is_binary(id) -> id
              _ -> nil
            end

          if is_binary(account_id), do: fun.(token, account_id), else: []

        _ ->
          []
      end
    rescue
      e ->
        Logger.error("Oanda.with_token (#{env}) crashed: #{inspect(e)}")
        []
    end
  end

  defp provider_for(:live), do: "oanda_live"
  defp provider_for(_), do: "oanda"

  @doc """
  Safely pull a string field from an OANDA position / instrument map.
  Returns `default` when the value is nil/empty or the row is not a map.
  Never raises.
  """
  def field(row, key, default \\ "—")

  def field(%{} = row, key, default) do
    case Map.get(row, key) do
      nil -> default
      "" -> default
      v when is_binary(v) -> v
      other -> to_string(other)
    end
  rescue
    _ -> default
  end

  def field(_, _, default), do: default
end
