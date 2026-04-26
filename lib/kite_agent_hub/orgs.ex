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
          %{
            collective_intelligence_enabled: true,
            collective_intelligence_consented_at: DateTime.utc_now(:second),
            collective_intelligence_consent_version: CollectiveIntelligence.consent_version()
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

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(&"#{&1}-#{System.unique_integer([:positive])}")
  end
end
