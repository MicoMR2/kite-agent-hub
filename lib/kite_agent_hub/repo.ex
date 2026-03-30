defmodule KiteAgentHub.Repo do
  use Ecto.Repo,
    otp_app: :kite_agent_hub,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Executes `fun` inside a transaction with `app.current_user_id` set
  to `user_id` for the duration of the transaction. All Postgres RLS
  policies read this value — call this wrapper around any query that
  must be tenant-scoped.

  ## Example

      Repo.with_user(current_scope.user.id, fn ->
        Repo.all(KiteAgent)
      end)
  """
  def with_user(user_id, fun) when is_integer(user_id) do
    with_user(Integer.to_string(user_id), fun)
  end

  def with_user(user_id, fun) when is_binary(user_id) do
    transaction(fn ->
      query!(
        "SELECT set_config('app.current_user_id', $1, true)",
        [user_id]
      )

      fun.()
    end)
  end

  @doc """
  Returns the owner user_id for an agent using a SECURITY DEFINER SQL function.
  Bypasses RLS — safe for trusted server processes (Oban workers, GenServers).
  """
  def owner_user_id_for_agent(agent_id) do
    case query!("SELECT owner_user_id_for_agent($1::uuid)", [agent_id]) do
      %{rows: [[user_id]]} -> user_id
      _ -> nil
    end
  end

  @doc """
  Returns all active agents with their owner user_ids using a SECURITY DEFINER function.
  Used at boot by AgentRunnerSupervisor to restart runners without a user context.
  """
  def active_agents_with_owners do
    case query!("SELECT agent_id, owner_user_id FROM active_agents_with_owners()", []) do
      %{rows: rows} ->
        Enum.map(rows, fn [agent_id, owner_user_id] -> {agent_id, owner_user_id} end)
    end
  end
end
