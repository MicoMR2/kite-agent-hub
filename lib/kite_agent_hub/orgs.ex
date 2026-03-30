defmodule KiteAgentHub.Orgs do
  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Orgs.{Organization, Membership}

  def get_org!(id), do: Repo.get!(Organization, id)

  def get_org_by_slug(slug), do: Repo.get_by(Organization, slug: slug)

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

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(&"#{&1}-#{System.unique_integer([:positive])}")
  end
end
