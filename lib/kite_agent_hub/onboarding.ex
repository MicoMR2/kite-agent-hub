defmodule KiteAgentHub.Onboarding do
  @moduledoc """
  Post-registration provisioning and wizard-state tracking.

  On first registration we create the user's default trading agent,
  an empty wallet, and an empty vault so the dashboard has something
  meaningful to show from the first page load. `provision_for_user/2`
  is safe to run inside the registration `Ecto.Multi` because every
  step is idempotent.

  Wizard-dismissal state is stored server-side on `users.onboarding_completed_at`
  — never in localStorage, so the user sees the same state across
  devices and a determined client cannot skip onboarding by
  tampering with browser storage.
  """

  alias KiteAgentHub.Accounts.User
  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.KiteAgent
  alias KiteAgentHub.{Vaults, Wallets}

  @default_agent_name "My Agent"

  @doc """
  Provision the default agent, wallet, and vault for a user. Returns
  `:ok` on success (agent/wallet/vault all exist after the call),
  `{:error, reason}` otherwise.
  """
  @spec provision_for_user(User.t(), Organization.t()) :: :ok | {:error, term()}
  def provision_for_user(%User{} = user, %Organization{} = org) do
    with {:ok, _agent} <- ensure_default_agent(user, org),
         {:ok, _wallet} <- Wallets.provision_for_user(user),
         {:ok, _vault} <- Vaults.provision_for_user(user) do
      :ok
    end
  end

  @doc "Mark the wizard as completed for this user."
  @spec complete_onboarding(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def complete_onboarding(%User{} = user) do
    user
    |> Ecto.Changeset.change(
      onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update()
  end

  @doc "True when the wizard has not been completed yet."
  @spec pending?(User.t()) :: boolean()
  def pending?(%User{onboarding_completed_at: nil}), do: true
  def pending?(%User{}), do: false

  # ── Internal ──────────────────────────────────────────────────────

  defp ensure_default_agent(%User{} = _user, %Organization{id: org_id}) do
    # The agent is org-scoped, not user-scoped. If the user's org
    # already has at least one agent we leave things alone — the user
    # may have been invited to an existing workspace.
    case Repo.get_by(KiteAgent, organization_id: org_id) do
      %KiteAgent{} = agent ->
        {:ok, agent}

      nil ->
        # Default onboarding agent. agent_type: "research" so we
        # don't need a wallet_address yet — the user upgrades it to
        # a trading agent in Phase 3 when Privy provisioning lands.
        %{
          name: @default_agent_name,
          agent_type: "research",
          organization_id: org_id,
          status: "pending"
        }
        |> then(&KiteAgent.changeset(%KiteAgent{}, &1))
        |> Repo.insert()
    end
  end
end
