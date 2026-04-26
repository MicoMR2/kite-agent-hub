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

  @doc """
  Fetch the account summary (balance, NAV, unrealized P&L) for the
  given env. Returns the raw `%{"account" => map}` payload or `nil`
  on any failure so the template can render `"—"`.
  """
  def account_summary(org_id, env \\ :practice) do
    case with_token(org_id, env, fn token, account_id ->
           case OandaClient.account_summary(token, account_id, env) do
             {:ok, %{"account" => account}} -> account
             _ -> nil
           end
         end) do
      [] -> nil
      v -> v
    end
  end

  @doc """
  Fetch OHLC candles for a single instrument. Returns a list of candle
  maps (as returned by OANDA) or `[]` on any failure.
  """
  def candles(org_id, instrument, granularity \\ "M5", count \\ 120, env \\ :practice) do
    with_token(org_id, env, fn token, _account_id ->
      case OandaClient.candles(token, instrument, granularity, count, env) do
        {:ok, %{"candles" => list}} when is_list(list) -> list
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
  Place a market order on the OANDA PRACTICE account for `org_id`.

  Requires a trading-agent; non-trading agents get `:not_a_trading_agent`.
  Live orders are intentionally not supported — this path hardcodes
  to the practice endpoint via OandaClient.place_practice_order/5.

  Returns `{:ok, body}` on 200/201 from OANDA, or `{:error, reason}`
  on any failure (missing creds, decryption, auth, transport).
  """
  def place_practice_order(agent, org_id, instrument, units),
    do: place_practice_order(agent, org_id, instrument, units, %{})

  def place_practice_order(%{agent_type: "trading"}, org_id, instrument, units, opts)
      when is_binary(instrument) and is_integer(units) do
    with_credential(org_id, :practice, fn token, account_id ->
      OandaClient.place_practice_order(token, account_id, instrument, units, opts)
    end)
  rescue
    e ->
      Logger.error("Oanda.place_practice_order crashed: #{inspect(e)}")
      {:error, :exception}
  end

  def place_practice_order(%{agent_type: _}, _org, _inst, _u, _opts),
    do: {:error, :not_a_trading_agent}

  def place_practice_order(_agent, _org, _inst, _u, _opts), do: {:error, :invalid_agent}

  # Like with_token/3 but propagates {:error, _} instead of collapsing
  # to []. Used by mutating paths (place_practice_order) where callers
  # need to distinguish "not configured" from a successful empty list.
  defp with_credential(org_id, env, fun) when is_function(fun, 2) do
    provider = provider_for(env)

    case Credentials.fetch_secret(org_id, String.to_atom(provider)) do
      {:ok, {_label, token}} ->
        case Credentials.get_credential(org_id, provider) do
          %{account_id: id} when is_binary(id) -> fun.(token, id)
          _ -> {:error, :missing_account_id}
        end

      _ ->
        {:error, :not_configured}
    end
  end

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

  @doc """
  Build a polyline `points` string from a list of OANDA candles, scaled
  to `width` × `height`. Uses the mid close price. Returns `""` when
  no usable prices are available so the template can omit the chart.
  """
  def sparkline_points(candles, width \\ 640, height \\ 120)

  def sparkline_points(candles, width, height) when is_list(candles) and candles != [] do
    closes =
      candles
      |> Enum.map(fn c -> get_in(c, ["mid", "c"]) end)
      |> Enum.map(fn
        s when is_binary(s) ->
          case Float.parse(s) do
            {f, _} -> f
            :error -> nil
          end

        n when is_number(n) ->
          n * 1.0

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    case closes do
      [] ->
        ""

      [_single] ->
        ""

      list ->
        min_v = Enum.min(list)
        max_v = Enum.max(list)
        range = max_v - min_v

        if range == 0 do
          ""
        else
          last_idx = length(list) - 1
          pad_y = 4.0
          inner_h = height - 2 * pad_y

          list
          |> Enum.with_index()
          |> Enum.map(fn {v, i} ->
            x = i / last_idx * width
            y = height - pad_y - (v - min_v) / range * inner_h
            "#{Float.round(x, 2)},#{Float.round(y, 2)}"
          end)
          |> Enum.join(" ")
        end
    end
  rescue
    _ -> ""
  end

  def sparkline_points(_, _, _), do: ""
end
