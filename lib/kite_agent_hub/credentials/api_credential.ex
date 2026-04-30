defmodule KiteAgentHub.Credentials.ApiCredential do
  @moduledoc """
  Schema for encrypted API credentials (Alpaca, Kalshi) scoped to an org.

  Secrets are encrypted at rest via AES-256-GCM (see Cipher module).
  The `:secret` virtual field is never persisted — only the encrypted bytes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias KiteAgentHub.Credentials.Cipher

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Broker, LLM, prediction-market, and forex providers share this
  # table. For :polymarket, key_id holds the Relayer address (0x + 40
  # hex chars). oanda and oanda_live are separate rows — practice uses
  # api-fxpractice.oanda.com, live uses api-fxtrade.oanda.com. The UI
  # renders them as two connector cards so paper and real-money keys
  # are never conflated.
  @valid_providers ~w(alpaca kalshi openai anthropic polymarket oanda oanda_live)

  schema "api_credentials" do
    field :org_id, :binary_id
    field :provider, :string
    field :key_id, :string
    field :env, :string, default: "paper"
    field :encrypted_secret, :binary
    field :iv, :binary
    field :tag, :binary
    field :account_id, :string
    field :server, :string

    # Virtual — holds plaintext secret during form submission only
    field :secret, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:org_id, :provider, :key_id, :secret, :env, :account_id, :server])
    |> validate_required([:org_id, :provider, :key_id, :secret])
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_inclusion(:env, @valid_envs)
    |> validate_length(:key_id, min: 4)
    |> validate_length(:secret, min: 8)
    |> validate_polymarket_address()
    |> validate_oanda_fields()
    |> encrypt_secret()
  end

  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:key_id, :secret, :env, :account_id, :server])
    |> validate_required([:key_id, :secret])
    |> validate_inclusion(:env, @valid_envs)
    |> validate_length(:key_id, min: 4)
    |> validate_length(:secret, min: 8)
    |> validate_polymarket_address()
    |> validate_oanda_fields()
    |> encrypt_secret()
  end

  # Polymarket-specific: key_id must be an EVM address (0x + 40 hex).
  # Public value, no encryption needed — but invalid format should
  # never hit the DB.
  defp validate_polymarket_address(changeset) do
    case get_field(changeset, :provider) do
      "polymarket" ->
        validate_format(
          changeset,
          :key_id,
          ~r/^0x[a-fA-F0-9]{40}$/,
          message: "must be a 0x-prefixed 40-hex-character EVM address"
        )

      _ ->
        changeset
    end
  end

  # OANDA: key_id holds a human label (optional name like "practice"),
  # secret holds the Personal Access Token, account_id must match the
  # NNN-NNN-XXXXXXX-NNN format OANDA uses.
  defp validate_oanda_fields(changeset) do
    case get_field(changeset, :provider) do
      p when p in ["oanda", "oanda_live"] ->
        validate_format(
          changeset,
          :account_id,
          ~r/^\d{3}-\d{3}-\d{6,8}-\d{3}$/,
          message: "must match OANDA format NNN-NNN-XXXXXXX-NNN"
        )

      _ ->
        changeset
    end
  end

  defp encrypt_secret(%{valid?: true, changes: %{secret: secret}} = changeset)
       when is_binary(secret) and secret != "" do
    {ciphertext, iv, tag} = Cipher.encrypt(secret)

    changeset
    |> put_change(:encrypted_secret, ciphertext)
    |> put_change(:iv, iv)
    |> put_change(:tag, tag)
    |> delete_change(:secret)
  end

  defp encrypt_secret(changeset), do: changeset
end
