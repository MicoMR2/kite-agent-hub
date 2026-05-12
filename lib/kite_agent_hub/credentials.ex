defmodule KiteAgentHub.Credentials do
  @moduledoc """
  Context for managing encrypted API credentials (Alpaca, Kalshi).

  Keys are always fetched with org_id scope — no cross-org reads possible.
  Plaintext secrets are never stored in assigns or logged.
  """

  import Ecto.Query
  require Logger

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Credentials.{ApiCredential, Cipher}

  @testnet_chain_id 2368
  @mainnet_chain_id 2366

  @doc """
  Single server-side helper that maps an agent + broker root to the
  exact ApiCredential provider slug to load (CyberSec ask 4, msg
  9176). Per-agent `chain_id` drives the choice:

    * `2368` (testnet) → paper slug (`alpaca` / `kalshi` / `oanda`)
    * `2366` (mainnet) → live slug (`alpaca_live` / `kalshi_live` /
      `oanda_live`)
    * `polymarket` is live-only — returns `"polymarket"` regardless
      of chain (CyberSec ask 3)

  Returns `{:ok, slug}` or `{:error, reason}`. Callers MUST go through
  this helper rather than constructing slugs at call sites — that
  duplication is the single security-critical surface CyberSec
  flagged for review.

  Log redaction: any error log emitted here shows only the broker
  root and the agent id, never the secret or key value (CyberSec
  ask 6).
  """
  @spec broker_slug_for(map(), atom() | binary()) ::
          {:ok, String.t()} | {:error, :invalid_broker}
  def broker_slug_for(agent, broker_root) when broker_root in [:polymarket, "polymarket"] do
    _ = agent
    {:ok, "polymarket"}
  end

  def broker_slug_for(agent, broker_root) when is_atom(broker_root),
    do: broker_slug_for(agent, Atom.to_string(broker_root))

  def broker_slug_for(%{chain_id: @testnet_chain_id} = _agent, broker_root)
      when broker_root in ["alpaca", "kalshi", "oanda"] do
    {:ok, broker_root}
  end

  def broker_slug_for(%{chain_id: @mainnet_chain_id, id: agent_id}, broker_root)
      when broker_root in ["alpaca", "kalshi", "oanda"] do
    slug = broker_root <> "_live"
    Logger.debug("broker_slug_for: agent_id=#{agent_id} slug=#{slug}")
    {:ok, slug}
  end

  def broker_slug_for(%{chain_id: nil} = agent, broker_root) do
    # Defensive fallback: agents created via KiteAgent.changeset get
    # chain_id filled by `fill_chain_id_default/1`, but if a row
    # somehow has nil, treat as paper so a missing config doesn't
    # accidentally route to a live broker.
    Logger.warning(
      "broker_slug_for: agent_id=#{agent.id} has nil chain_id — defaulting to paper slug for safety"
    )

    broker_slug_for(%{agent | chain_id: @testnet_chain_id}, broker_root)
  end

  def broker_slug_for(%{id: agent_id, chain_id: cid}, broker_root) do
    Logger.warning(
      "broker_slug_for: agent_id=#{agent_id} unknown broker_root=#{inspect(broker_root)} chain_id=#{inspect(cid)}"
    )

    {:error, :invalid_broker}
  end

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
  LLM-specific wrapper around `fetch_secret_with_env/2`. Returns the
  decrypted API key for the given org + LLM provider, or
  `{:error, :not_configured}` when the org has not set one up. The
  `env` field is irrelevant for LLM providers, so we drop it.
  """
  def fetch_llm_key(org_id, provider) when provider in ~w(openai anthropic) do
    case fetch_secret_with_env(org_id, provider) do
      {:ok, {_key_id, secret, _env}} -> {:ok, secret}
      {:error, _} = err -> err
    end
  end

  def fetch_llm_key(_org_id, _provider), do: {:error, :not_supported}

  @doc """
  Upsert a credential for an org + provider. Returns {:ok, credential} or {:error, changeset}.

  Pass `actor_user_id` to enable audit logging for live-slot mutations
  (CyberSec ask 8 on PR #364). When nil, no audit row is written —
  used by tests and internal call sites that don't have a user
  context.
  """
  def upsert_credential(org_id, provider, attrs, actor_user_id \\ nil) do
    provider_str = to_string(provider)
    attrs = Map.merge(attrs, %{"org_id" => org_id, "provider" => provider_str})

    result =
      case get_credential(org_id, provider_str) do
        nil ->
          %ApiCredential{}
          |> ApiCredential.changeset(attrs)
          |> Repo.insert()
          |> tag_action(:credential_created)

        existing ->
          existing
          |> ApiCredential.update_changeset(attrs)
          |> Repo.update()
          |> tag_action(:credential_updated)
      end

    audit_if_live(result, actor_user_id, org_id, provider_str)

    case result do
      {:ok, {value, _action}} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  @doc """
  Delete a credential. Silently succeeds if not found.

  Pass `actor_user_id` to enable audit logging for live-slot deletes.
  """
  def delete_credential(org_id, provider, actor_user_id \\ nil) do
    provider_str = to_string(provider)

    case get_credential(org_id, provider_str) do
      nil ->
        :ok

      credential ->
        case Repo.delete(credential) do
          {:ok, _} = ok ->
            audit_if_live({:ok, {credential, :credential_deleted}}, actor_user_id, org_id, provider_str)
            ok

          {:error, _} = err ->
            err
        end
    end
  end

  defp tag_action({:ok, value}, action), do: {:ok, {value, action}}
  defp tag_action({:error, _} = err, _action), do: err

  defp audit_if_live({:ok, {_value, action}}, actor_user_id, org_id, provider)
       when not is_nil(actor_user_id) do
    if provider in ApiCredential.live_providers() do
      KiteAgentHub.Audit.log_live_credential_event(
        actor_user_id,
        org_id,
        action,
        provider,
        %{}
      )
    end

    :ok
  end

  defp audit_if_live(_, _, _, _), do: :ok

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
