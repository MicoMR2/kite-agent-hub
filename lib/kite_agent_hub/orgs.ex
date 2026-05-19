defmodule KiteAgentHub.Orgs do
  import Ecto.Query
  alias KiteAgentHub.{CollectiveIntelligence, Repo}
  alias KiteAgentHub.Orgs.{Organization, Membership}

  def get_org!(id), do: Repo.get!(Organization, id)

  def get_org_by_slug(slug), do: Repo.get_by(Organization, slug: slug)

  def get_org_owner_user_id(org_id) do
    Membership
    |> where(organization_id: ^org_id, role: "owner")
    |> select([m], m.user_id)
    |> limit(1)
    |> Repo.one()
  end

  def get_org_for_user(user_id) do
    list_orgs_for_user(user_id) |> List.first()
  end

  def list_orgs_for_user(user_id) do
    Organization
    |> join(:inner, [o], m in Membership, on: m.organization_id == o.id)
    |> where([_, m], m.user_id == ^user_id)
    |> Repo.all()
  end

  def create_org_for_user(user, attrs) do
    slug = attrs[:slug] || attrs["slug"] || slugify(attrs[:name] || attrs["name"] || "")

    Ecto.Multi.new()
    |> Ecto.Multi.insert(
      :org,
      Organization.changeset(%Organization{}, Map.put(attrs, :slug, slug))
    )
    |> Ecto.Multi.insert(:membership, fn %{org: org} ->
      Membership.changeset(%Membership{}, %{
        user_id: user.id,
        organization_id: org.id,
        role: "owner"
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{org: org}} -> {:ok, org}
      {:error, :org, changeset, _} -> {:error, changeset}
      {:error, _, _, _} -> {:error, :failed}
    end
  end

  def can_manage_org?(user_id, org_id) do
    Repo.with_user(user_id, fn ->
      Membership
      |> where([m], m.user_id == ^user_id)
      |> where([m], m.organization_id == ^org_id)
      |> where([m], m.role in ["owner", "admin"])
      |> Repo.exists?()
    end)
    |> case do
      {:ok, result} -> result
      _ -> false
    end
  end

  def update_collective_intelligence(user, org_id, enabled) when is_boolean(enabled) do
    if can_manage_org?(user.id, org_id) do
      attrs =
        if enabled do
          # PR-K3b backwards-compat fix: the v1 enable toggle MUST
          # pin to the baseline v1 string, NOT @consent_version
          # which is now v2 ("kci-v2-2026-05-19" post-K3a). Pre-fix
          # this auto-extended every new v1 opt-in into v2 silently
          # — violates CyberSec 10831 ②/⑦. v2 opt-in is a separate
          # explicit action via `update_kci_v2_consent/3`.
          %{
            collective_intelligence_enabled: true,
            collective_intelligence_consented_at: DateTime.utc_now(:second),
            collective_intelligence_consent_version: CollectiveIntelligence.prior_consent_version()
          }
        else
          %{
            collective_intelligence_enabled: false,
            collective_intelligence_consented_at: nil,
            collective_intelligence_consent_version: nil
          }
        end

      result =
        Repo.with_user(user.id, fn ->
          org_id
          |> get_org!()
          |> Organization.collective_intelligence_changeset(attrs)
          |> Repo.update()
        end)

      case result do
        {:ok, {:ok, org}} ->
          if not enabled, do: CollectiveIntelligence.purge_org_contributions(org.id)
          {:ok, org}

        {:ok, {:error, changeset}} ->
          {:error, changeset}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :forbidden}
    end
  end

  def update_collective_intelligence(_user, _org_id, _enabled), do: {:error, :invalid_enabled}

  @doc """
  PR-K3b: separately toggle v2 (Kalshi-specific buckets) opt-in.
  Distinct from `update_collective_intelligence/3` so v1 + v2
  consents stay independent — turning on v1 does NOT extend to v2,
  and v2 enable is gated on v1 already being enabled.

  Enabling sets `collective_intelligence_consent_version` to the
  current `CollectiveIntelligence.consent_version()`
  ("kci-v2-2026-05-19"). Disabling drops back to the v1 prior
  version (keeps the base v1 opt-in active; user opted-out only
  of the v2 surface).
  """
  def update_kci_v2_consent(user, org_id, enabled) when is_boolean(enabled) do
    if can_manage_org?(user.id, org_id) do
      org = get_org!(org_id)

      cond do
        not org.collective_intelligence_enabled ->
          {:error, :v1_not_enabled}

        true ->
          version =
            if enabled,
              do: CollectiveIntelligence.consent_version(),
              else: CollectiveIntelligence.prior_consent_version()

          attrs = %{
            collective_intelligence_enabled: true,
            collective_intelligence_consented_at: DateTime.utc_now(:second),
            collective_intelligence_consent_version: version
          }

          case Repo.with_user(user.id, fn ->
                 org
                 |> Organization.collective_intelligence_changeset(attrs)
                 |> Repo.update()
               end) do
            {:ok, {:ok, org}} -> {:ok, org}
            {:ok, {:error, cs}} -> {:error, cs}
            {:error, reason} -> {:error, reason}
          end
      end
    else
      {:error, :forbidden}
    end
  end

  def update_kci_v2_consent(_user, _org_id, _enabled), do: {:error, :invalid_enabled}

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(&"#{&1}-#{System.unique_integer([:positive])}")
  end
end
