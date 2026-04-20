defmodule KiteAgentHub.Trading.KiteAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending active paused error archived)
  @agent_types ~w(trading research conversational)
  @llm_providers ~w(anthropic openai ollama)

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

    # BYO-model fields. Null means "inherit from org default". The
    # field validation below guards the provider string; SSRF
    # validation for llm_endpoint_url lives with the provider
    # dispatcher (follow-up PR) — this schema only stores the value.
    field :llm_provider, :string
    field :llm_model, :string
    field :llm_endpoint_url, :string

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
  does NOT accept api_token, wallet_address, organization_id, or
  status: API key rotation is server-driven, the wallet is
  provisioned once, orgs can't be reassigned via this endpoint, and
  status moves through its own lifecycle (activate / pause / archive).
  """
  def profile_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :tags, :bio])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:bio, max: 2000)
    |> validate_tags()
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

  defp validate_wallet_for_trading(changeset) do
    agent_type = get_field(changeset, :agent_type) || "trading"

    if agent_type == "trading" do
      validate_required(changeset, [:wallet_address])
    else
      # Normalize empty string to nil so the unique constraint doesn't fire
      # and validate_evm_address doesn't reject a blank value
      case get_change(changeset, :wallet_address) do
        "" -> put_change(changeset, :wallet_address, nil)
        _ -> changeset
      end
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
