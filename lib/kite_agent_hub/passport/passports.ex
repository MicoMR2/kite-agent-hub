defmodule KiteAgentHub.Passport.Passports do
  @moduledoc """
  Context for BYO-Passport linking + payment rail selection
  (passport-handoff §5 PR-5).

  Single write surface for `agent_passport_links` — every insert and
  update routes through `AgentPassportLink.changeset/2` so the
  non-custodial-invariant validators (JWT-shape reject, length caps,
  EVM regex) cannot be bypassed.

  Ownership is enforced at two layers:

    1. Each function wraps its mutation in `Repo.with_user/2` so the
       Postgres RLS policy sees the calling user.
    2. The caller (LiveView handler) must additionally verify
       `agent.organization_id == current_scope.user.org_id` before
       invoking these functions — the explicit belt against any
       future RLS-policy regression (CyberSec ask 5, msg 9093 / 9100).
  """

  import Ecto.Query

  alias KiteAgentHub.Accounts.AgentPassportLink
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.KiteAgent

  @spec get_active_link(binary()) :: AgentPassportLink.t() | nil
  def get_active_link(agent_id) when is_binary(agent_id) do
    Repo.one(
      from l in AgentPassportLink,
        where: l.agent_id == ^agent_id and l.active == true,
        limit: 1
    )
  end

  @spec link_agent(integer(), KiteAgent.t(), map()) ::
          {:ok, AgentPassportLink.t()} | {:error, Ecto.Changeset.t()}
  def link_agent(user_id, %KiteAgent{} = agent, attrs)
      when is_integer(user_id) and is_map(attrs) do
    Repo.with_user(user_id, fn ->
      %AgentPassportLink{}
      |> AgentPassportLink.changeset(Map.put(attrs, "agent_id", agent.id))
      |> Repo.insert()
    end)
    |> unwrap_with_user()
  end

  @spec unlink_agent(integer(), AgentPassportLink.t()) ::
          {:ok, AgentPassportLink.t()} | {:error, Ecto.Changeset.t()}
  def unlink_agent(user_id, %AgentPassportLink{} = link) when is_integer(user_id) do
    Repo.with_user(user_id, fn ->
      link
      |> AgentPassportLink.changeset(%{"active" => false})
      |> Repo.update()
    end)
    |> unwrap_with_user()
  end

  @spec change_payment_rail(integer(), KiteAgent.t(), String.t()) ::
          {:ok, KiteAgent.t()} | {:error, Ecto.Changeset.t() | :invalid_rail}
  def change_payment_rail(user_id, %KiteAgent{} = agent, rail)
      when is_integer(user_id) and is_binary(rail) do
    if rail in KiteAgent.payment_rails() do
      Repo.with_user(user_id, fn ->
        agent
        |> Ecto.Changeset.cast(%{"payment_rail" => rail}, [:payment_rail])
        |> Ecto.Changeset.validate_inclusion(:payment_rail, KiteAgent.payment_rails())
        |> Repo.update()
      end)
      |> unwrap_with_user()
    else
      {:error, :invalid_rail}
    end
  end

  # `Repo.with_user/2` wraps the inner result in `{:ok, value}`. Unwrap
  # so callers get the standard `{:ok, _} | {:error, _}` shape.
  # (See feedback_kah_with_user_destructure.md — May 7 bug.)
  defp unwrap_with_user({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_with_user({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_with_user({:error, reason}), do: {:error, reason}

  @spec list_active_links_for_org(binary()) :: [AgentPassportLink.t()]
  def list_active_links_for_org(org_id) when is_binary(org_id) do
    Repo.all(
      from l in AgentPassportLink,
        join: a in KiteAgent,
        on: a.id == l.agent_id,
        where: a.organization_id == ^org_id and l.active == true
    )
  end

  @doc """
  Map keyed by agent_id → active link. Convenience for LiveView mount.
  """
  @spec active_links_by_agent([KiteAgent.t()]) :: %{binary() => AgentPassportLink.t()}
  def active_links_by_agent(agents) when is_list(agents) do
    case agents do
      [] ->
        %{}

      _ ->
        agent_ids = Enum.map(agents, & &1.id)

        from(l in AgentPassportLink,
          where: l.agent_id in ^agent_ids and l.active == true
        )
        |> Repo.all()
        |> Map.new(fn link -> {link.agent_id, link} end)
    end
  end
end
