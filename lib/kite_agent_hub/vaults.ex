defmodule KiteAgentHub.Vaults do
  @moduledoc """
  Context for per-user encrypted credential vaults.

  The vault stores a single JSON blob of platform credentials
  (Alpaca keys, OANDA tokens, Kalshi creds, etc) encrypted with
  AES-256-GCM. Each vault row has its own random 12-byte IV; the
  symmetric key is read from `VAULT_ENCRYPTION_KEY` (Fly secret —
  never hardcoded).

  All public functions take `%User{}` so queries never leak across
  users on a raw record-id lookup.
  """

  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Accounts.User
  alias KiteAgentHub.Vaults.Vault

  @spec get_for_user(User.t()) :: Vault.t() | nil
  def get_for_user(%User{id: user_id}) do
    Repo.get_by(Vault, user_id: user_id)
  end

  @doc """
  Provision an empty vault row for a user. Idempotent.
  """
  @spec provision_for_user(User.t()) :: {:ok, Vault.t()} | {:error, Ecto.Changeset.t()}
  def provision_for_user(%User{id: user_id}) do
    case Repo.get_by(Vault, user_id: user_id) do
      %Vault{} = vault ->
        {:ok, vault}

      nil ->
        %{user_id: user_id}
        |> Vault.create_changeset()
        |> Repo.insert()
    end
  end

  @doc """
  Store a map of credentials encrypted for this user. The plaintext
  blob is JSON-encoded, then encrypted with a fresh IV. Returns the
  updated `%Vault{}`.
  """
  @spec put_credentials(User.t(), map()) :: {:ok, Vault.t()} | {:error, term()}
  def put_credentials(%User{} = user, %{} = credentials) do
    with {:ok, vault} <- provision_for_user(user),
         {:ok, plaintext} <- Jason.encode(credentials) do
      iv = :crypto.strong_rand_bytes(12)
      ciphertext = encrypt(plaintext, iv)

      vault
      |> Vault.put_payload_changeset(ciphertext, iv)
      |> Repo.update()
    end
  end

  @doc """
  Decrypt and return the credentials map, or `{:ok, %{}}` if the
  vault has never been written to.
  """
  @spec read_credentials(User.t()) :: {:ok, map()} | {:error, term()}
  def read_credentials(%User{id: user_id}) do
    case Repo.one(from v in Vault, where: v.user_id == ^user_id) do
      nil -> {:ok, %{}}
      %Vault{encrypted_credentials: nil} -> {:ok, %{}}
      %Vault{encrypted_credentials: ct, iv: iv} -> decrypt_and_decode(ct, iv)
    end
  end

  # ── Encryption primitives ──────────────────────────────────────────

  defp encrypt(plaintext, iv) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key!(), iv, plaintext, <<>>, true)

    # Persist tag || ciphertext so the 16-byte tag is self-contained
    # inside `encrypted_credentials`. iv lives in its own column.
    <<tag::binary-size(16), ciphertext::binary>>
  end

  defp decrypt_and_decode(<<tag::binary-size(16), ciphertext::binary>>, iv) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key!(), iv, ciphertext, <<>>, tag, false) do
      plaintext when is_binary(plaintext) -> Jason.decode(plaintext)
      _ -> {:error, :decrypt_failed}
    end
  end

  defp decrypt_and_decode(_, _), do: {:error, :bad_ciphertext}

  defp key! do
    case System.get_env("VAULT_ENCRYPTION_KEY") do
      nil ->
        raise """
        VAULT_ENCRYPTION_KEY is not set. Generate one with:
            mix run -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'
        and set it as a Fly secret:
            fly secrets set VAULT_ENCRYPTION_KEY=<base64 32-byte key>
        """

      encoded ->
        case Base.decode64(encoded) do
          {:ok, <<key::binary-size(32)>>} ->
            key

          _ ->
            raise "VAULT_ENCRYPTION_KEY must decode to exactly 32 bytes (base64)"
        end
    end
  end
end
