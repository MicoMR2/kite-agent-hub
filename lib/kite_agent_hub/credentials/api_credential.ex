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

  # Broker providers (alpaca/kalshi) and LLM providers (openai/anthropic)
  # share the same encrypted-secret storage. Ollama is omitted because it
  # authenticates via a base URL only — no shared secret to store.
  @valid_providers ~w(alpaca kalshi openai anthropic)
  @valid_envs ~w(paper live)

  schema "api_credentials" do
    field :org_id, :binary_id
    field :provider, :string
    field :key_id, :string
    field :env, :string, default: "paper"
    field :encrypted_secret, :binary
    field :iv, :binary
    field :tag, :binary

    # Virtual — holds plaintext secret during form submission only
    field :secret, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:org_id, :provider, :key_id, :secret, :env])
    |> validate_required([:org_id, :provider, :key_id, :secret])
    |> validate_inclusion(:provider, @valid_providers)
    |> validate_inclusion(:env, @valid_envs)
    |> validate_length(:key_id, min: 4)
    |> validate_length(:secret, min: 8)
    |> encrypt_secret()
  end

  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:key_id, :secret, :env])
    |> validate_required([:key_id, :secret])
    |> validate_inclusion(:env, @valid_envs)
    |> validate_length(:key_id, min: 4)
    |> validate_length(:secret, min: 8)
    |> encrypt_secret()
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
