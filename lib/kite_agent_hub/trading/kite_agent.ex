defmodule KiteAgentHub.Trading.KiteAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending active paused error archived)
  @agent_types ~w(trading research conversational)
  @llm_providers ~w(anthropic openai)

  # Whitelist of markets an agent can be configured to trade. Surfaced
  # in onboarding as the multi-select. Each value maps to the broker /
  # data source used in trading-agent.codex.md.
  @markets ~w(equities options crypto forex prediction_markets)
  def markets, do: @markets

  schema "kite_agents" do
    field :name, :string
    field :agent_type, :string, default: "trading"
    field :wallet_address, :string
    field :vault_address, :string
    field :chain_id, :integer, default: 2368
    field :status, :string, default: "pending"
    field :api_token, :string
    field :tags, {:array, :string}, default: []
    field :bio, :string
    field :markets, {:array, :string}, default: []

    # Trading without Kite chain attestations is the default. When this
    # is true, the agent must have a wallet_address (validated below)
    # AND the post-settlement attestation worker will submit an on-chain
    # transfer for every settled trade. When false (default), the agent
    # can trade Alpaca/Kalshi/OANDA freely with no Kite-chain coupling.
    field :attestations_enabled, :boolean, default: false

    # BYO-model fields. Null means "inherit from org default". The
    # field validation below guards the provider string; SSRF
    # validation for llm_endpoint_url lives with the provider
    # dispatcher (follow-up PR) — this schema only stores the value.
    field :llm_provider, :string
    field :llm_model, :string
    field :llm_endpoint_url, :string

    # Per-agent risk overrides. Empty map = "use module-level defaults
    # in Trading.Risk". Whitelisted keys only — see risk_config_changeset/2.
    field :risk_config, :map, default: %{}

    belongs_to :organization, KiteAgentHub.Orgs.Organization
    has_many :trade_records, KiteAgentHub.Trading.TradeRecord

    timestamps(type: :utc_datetime)
  end

  # Full changeset — used on creation only
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :agent_type,
      :wallet_address,
      :vault_address,
      :chain_id,
      :status,
      :organization_id,
      :attestations_enabled,
      :markets,
      :llm_provider,
      :llm_model,
      :llm_endpoint_url
    ])
    |> validate_required([:name, :organization_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_type, @agent_types)
    |> validate_inclusion(:llm_provider, @llm_providers)
    |> validate_wallet_for_trading()
    |> validate_evm_address(:wallet_address)
    |> validate_evm_address(:vault_address)
    |> validate_markets()
    |> maybe_generate_api_token()
    |> unique_constraint(:wallet_address)
    |> unique_constraint(:api_token)
  end

  # Name-only update
  def name_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  @doc """
  Profile update — the whitelist PATCH /agents/:id exposes. Explicitly
  does NOT accept api_token, organization_id, or status: API key
  rotation is server-driven, orgs can't be reassigned via this
  endpoint, and status moves through its own lifecycle.

  DOES accept `wallet_address`, `vault_address`, and
  `attestations_enabled` so users can flip Kite-chain attestations
  on/off for an existing agent and supply a wallet at the same time.
  Validation enforces the on-chain pair: enabling attestations
  requires a valid wallet_address.
  """
  def profile_changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :tags,
      :bio,
      :wallet_address,
      :vault_address,
      :attestations_enabled,
      :markets
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:bio, max: 2000)
    |> validate_tags()
    |> validate_markets()
    |> validate_wallet_for_trading()
    |> validate_evm_address(:wallet_address)
    |> validate_evm_address(:vault_address)
    |> unique_constraint(:wallet_address)
  end

  @doc "Rotate the api_token to a new server-generated value."
  def rotate_token_changeset(agent) do
    token = "kite_" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    cast(agent, %{api_token: token}, [:api_token])
  end

  @doc "Flip an agent to archived (soft-delete)."
  def archive_changeset(agent) do
    agent
    |> cast(%{status: "archived"}, [:status])
    |> validate_inclusion(:status, @statuses)
  end

  # Whitelist for risk_config keys + their string equivalents (form
  # input arrives as string keys; persisted JSONB also has string keys).
  @risk_keys ~w(
    per_trade_notional_cap_usd
    profit_trim_partial_pct
    profit_trim_full_pct
    market_hours_only
  )

  @doc """
  Schemaless changeset for risk_config edits. The form (or any caller)
  passes a flat map under `:risk_config`; this enforces the whitelist
  and bounds, never raw map merge.

  Validations:
    * per_trade_notional_cap_usd — Decimal, > 0, ≤ 5000 (server hard ceiling).
    * profit_trim_partial_pct — integer 0..100.
    * profit_trim_full_pct — integer 0..100, must be greater than partial.
    * market_hours_only — boolean.
    * Unknown keys → :unknown_key error on :risk_config.

  An empty / nil submission clears the override and falls back to
  Trading.Risk defaults at runtime.
  """
  def risk_config_changeset(agent, attrs) do
    raw = Map.get(attrs, "risk_config", Map.get(attrs, :risk_config, %{})) || %{}

    types = %{
      per_trade_notional_cap_usd: :decimal,
      profit_trim_partial_pct: :integer,
      profit_trim_full_pct: :integer,
      market_hours_only: :boolean
    }

    inner =
      {%{}, types}
      |> cast(stringify_keys(raw), Map.keys(types))
      |> validate_no_unknown_keys(raw)
      |> validate_number(:per_trade_notional_cap_usd,
        greater_than: Decimal.new(0),
        less_than_or_equal_to: KiteAgentHub.Trading.Risk.notional_ceiling_usd()
      )
      |> validate_number(:profit_trim_partial_pct,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> validate_number(:profit_trim_full_pct,
        greater_than_or_equal_to: 0,
        less_than_or_equal_to: 100
      )
      |> validate_full_above_partial()

    base = change(agent)

    if inner.valid? do
      sanitized =
        inner.changes
        |> Enum.into(%{}, fn {k, v} -> {Atom.to_string(k), serialize(v)} end)

      put_change(base, :risk_config, sanitized)
    else
      Enum.reduce(inner.errors, base, fn {field, {msg, opts}}, acc ->
        add_error(acc, :risk_config, "#{field}: #{msg}", opts)
      end)
    end
  end

  # Form params arrive as string keys; persisted JSONB is also string
  # keys. Normalize once at the boundary so the schemaless cast can
  # consume either shape.
  defp stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp validate_no_unknown_keys(changeset, raw) when is_map(raw) do
    raw
    |> stringify_keys()
    |> Map.keys()
    |> Enum.reject(&(&1 in @risk_keys))
    |> case do
      [] -> changeset
      [unknown | _] -> add_error(changeset, :risk_config, "unknown key: #{unknown}")
    end
  end

  defp validate_no_unknown_keys(changeset, _), do: changeset

  defp validate_full_above_partial(changeset) do
    partial = get_field(changeset, :profit_trim_partial_pct)
    full = get_field(changeset, :profit_trim_full_pct)

    cond do
      is_nil(partial) or is_nil(full) -> changeset
      full > partial -> changeset
      true -> add_error(changeset, :profit_trim_full_pct, "must be greater than partial")
    end
  end

  defp serialize(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp serialize(v), do: v

  defp validate_markets(changeset) do
    validate_change(changeset, :markets, fn _, markets ->
      cond do
        not is_list(markets) ->
          [{:markets, "must be a list of strings"}]

        Enum.any?(markets, fn m -> m not in @markets end) ->
          [{:markets, "contains an invalid market"}]

        length(Enum.uniq(markets)) != length(markets) ->
          [{:markets, "contains duplicates"}]

        true ->
          []
      end
    end)
  end

  defp validate_tags(changeset) do
    validate_change(changeset, :tags, fn _, tags ->
      cond do
        not is_list(tags) ->
          [{:tags, "must be a list of strings"}]

        length(tags) > 20 ->
          [{:tags, "max 20 tags"}]

        Enum.any?(tags, fn t -> not is_binary(t) or byte_size(t) == 0 or byte_size(t) > 64 end) ->
          [{:tags, "each tag must be 1..64 chars"}]

        true ->
          []
      end
    end)
  end

  # Wallet is required only when attestations are explicitly enabled.
  # This lets users (and their agents) trade Alpaca/Kalshi/OANDA
  # without any Kite-chain coupling, and opt-in later by flipping the
  # toggle and supplying a wallet in the same form submit.
  defp validate_wallet_for_trading(changeset) do
    attestations_on? = get_field(changeset, :attestations_enabled) == true

    changeset =
      case get_change(changeset, :wallet_address) do
        "" -> put_change(changeset, :wallet_address, nil)
        _ -> changeset
      end

    if attestations_on? do
      validate_required(changeset, [:wallet_address],
        message: "is required when attestations are enabled"
      )
    else
      changeset
    end
  end

  defp validate_evm_address(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if is_nil(value) or value == "" do
        []
      else
        if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, value) do
          []
        else
          [{field, "must be a valid EVM address (0x + 40 hex chars)"}]
        end
      end
    end)
  end

  defp maybe_generate_api_token(changeset) do
    if get_field(changeset, :api_token) do
      changeset
    else
      token = "kite_" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
      put_change(changeset, :api_token, token)
    end
  end
end
