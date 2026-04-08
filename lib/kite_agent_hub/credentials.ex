defmodule KiteAgentHub.Credentials do
  @moduledoc """
  Context for managing encrypted API credentials (Alpaca, Kalshi).

  Keys are always fetched with org_id scope — no cross-org reads possible.
  Plaintext secrets are never stored in assigns or logged.
  """

  import Ecto.Query

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Credentials.{ApiCredential, Cipher}

  @doc """
  Get the credential for a given org and provider (:alpaca | :kalshi).
  Returns `nil` if not set.
  """
  def get_credential(org_id, provider) do
    Repo.get_by(ApiCredential, org_id: org_id, provider: to_string(provider))
  end

  @doc """
  Decrypt and return {key_id, secret} for a given org + provider.
  Returns {:ok, {key_id, secret}} or {:error, reason}.

  Back-compat shape — use `fetch_secret_with_env/2` when the caller
  needs the paper/live routing hint (AlpacaClient, KalshiClient).
  """
  def fetch_secret(org_id, provider) do
    case get_credential(org_id, provider) do
      nil ->
        {:error, :not_configured}

      %ApiCredential{key_id: key_id, encrypted_secret: ct, iv: iv, tag: tag} ->
        case Cipher.decrypt(ct, iv, tag) do
          {:ok, secret} -> {:ok, {key_id, secret}}
          {:error, _} -> {:error, :decryption_failed}
        end
    end
  end

  @doc """
  Decrypt and return `{key_id, secret, env}` for a given org + provider.

  `env` is either `"paper"` (default, safe) or `"live"` — platform
  clients use this to pick the correct base URL at call time.
  """
  def fetch_secret_with_env(org_id, provider) do
    case get_credential(org_id, provider) do
      nil ->
        {:error, :not_configured}

      %ApiCredential{key_id: key_id, encrypted_secret: ct, iv: iv, tag: tag, env: env} ->
        case Cipher.decrypt(ct, iv, tag) do
          {:ok, secret} -> {:ok, {key_id, secret, env || "paper"}}
          {:error, _} -> {:error, :decryption_failed}
        end
    end
  end

  @doc """
  Upsert a credential for an org + provider. Returns {:ok, credential} or {:error, changeset}.
  """
  def upsert_credential(org_id, provider, attrs) do
    attrs = Map.merge(attrs, %{"org_id" => org_id, "provider" => to_string(provider)})

    case get_credential(org_id, provider) do
      nil ->
        %ApiCredential{}
        |> ApiCredential.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> ApiCredential.update_changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Delete a credential. Silently succeeds if not found.
  """
  def delete_credential(org_id, provider) do
    case get_credential(org_id, provider) do
      nil -> :ok
      credential -> Repo.delete(credential)
    end
  end

  @doc """
  List all configured providers for an org. Returns list of provider strings.
  """
  def configured_providers(org_id) do
    ApiCredential
    |> where([c], c.org_id == ^org_id)
    |> select([c], c.provider)
    |> Repo.all()
  end

  @doc """
  Mask a credential key_id for display — shows first 4 chars + asterisks.
  """
  def mask_key_id(nil), do: "—"

  def mask_key_id(key_id) when byte_size(key_id) >= 4 do
    prefix = binary_part(key_id, 0, 4)
    prefix <> String.duplicate("*", 8)
  end

  def mask_key_id(key_id), do: key_id
end
