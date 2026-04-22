defmodule KiteAgentHub.Polymarket do
  @moduledoc """
  Context for Polymarket integration.

  `mode/0` returns `:paper` or `:live` based on the application env
  (`:kite_agent_hub, :polymarket_mode`). In `:paper` mode, orders
  simulate fills against live Gamma prices and persist virtual
  positions — no CLOB calls are made. In `:live` mode (not yet
  implemented) orders would route to the CLOB API via a signed
  client; that path is intentionally left unimplemented until a
  funded wallet is configured.
  """

  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Polymarket.Position
  alias KiteAgentHub.TradingPlatforms.PolymarketClient

  @doc "Current operating mode (:paper or :live)."
  def mode do
    Application.get_env(:kite_agent_hub, :polymarket_mode, :paper)
  end

  @doc "Is the platform live (real CLOB orders)? Defaults to false."
  def live?, do: mode() == :live

  @doc "List Gamma markets for display. Never raises."
  def list_markets(opts \\ []) do
    case PolymarketClient.list_markets(opts) do
      {:ok, markets} -> markets
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc "List all positions for an organization."
  def list_positions(org_id) when is_binary(org_id) do
    from(p in Position, where: p.organization_id == ^org_id, order_by: [desc: p.inserted_at])
    |> Repo.all()
  end

  @doc "List positions for a single agent in an org."
  def list_agent_positions(org_id, agent_id) when is_binary(org_id) and is_binary(agent_id) do
    from(p in Position,
      where: p.organization_id == ^org_id and p.kite_agent_id == ^agent_id,
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Does this agent have permission to act on Polymarket?
  Trading agents can place orders; research / conversational / other
  types are view-only. Callers should gate any UI order-entry path on
  this predicate (CyberSec condition ⑫/⑬).
  """
  def can_trade?(nil), do: false
  def can_trade?(%{agent_type: "trading"}), do: true
  def can_trade?(_), do: false

  @doc """
  Format a Polymarket price value for display. Accepts numbers,
  numeric strings, or `nil` — never raises. Returns a 3-decimal
  string or "--" when no price is available.
  """
  def format_price(value) do
    num =
      cond do
        is_number(value) ->
          value * 1.0

        is_binary(value) ->
          case Float.parse(value) do
            {n, _} -> n
            :error -> nil
          end

        true ->
          nil
      end

    case num do
      nil -> "--"
      n -> :erlang.float_to_binary(n, decimals: 3)
    end
  rescue
    _ -> "--"
  end

  @doc """
  Safely read a string field from a Gamma market map. Returns `default`
  when `market` is not a map or the value is nil/empty.
  """
  def market_field(market, key, default \\ "—")

  def market_field(%{} = market, key, default) do
    case Map.get(market, key) do
      nil -> default
      "" -> default
      v when is_binary(v) -> v
      other -> to_string(other)
    end
  rescue
    _ -> default
  end

  def market_field(_, _, default), do: default

  @doc """
  Simulate a paper order fill at `price` and insert a position row.

  Enforces the trading-agent gate: the `agent` argument must be a
  struct with `agent_type == "trading"` or we return
  `{:error, :not_a_trading_agent}`.

  `attrs` must include `:market_id`, `:token_id`, `:outcome`, `:size`,
  `:price`, `:organization_id`. Returns `{:ok, position}`,
  `{:error, :not_a_trading_agent}`, `{:error, :live_mode_disabled}`,
  `{:error, :invalid_agent}`, or `{:error, changeset}`.
  """
  def place_paper_order(%{agent_type: "trading", id: agent_id}, attrs)
      when is_map(attrs) do
    if mode() == :paper do
      %Position{}
      |> Position.changeset(%{
        market_id: Map.get(attrs, :market_id),
        token_id: Map.get(attrs, :token_id),
        outcome: Map.get(attrs, :outcome),
        size: Map.get(attrs, :size, 0),
        avg_price: Map.get(attrs, :price, 0),
        organization_id: Map.get(attrs, :organization_id),
        kite_agent_id: agent_id,
        mode: "paper",
        status: "open"
      })
      |> Repo.insert()
    else
      {:error, :live_mode_disabled}
    end
  end

  def place_paper_order(%{agent_type: _}, _attrs), do: {:error, :not_a_trading_agent}
  def place_paper_order(_agent, _attrs), do: {:error, :invalid_agent}
end
