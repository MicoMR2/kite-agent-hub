defmodule KiteAgentHub.Kite.AgentRunnerSupervisor do
  @moduledoc """
  DynamicSupervisor that manages one AgentRunner per active Kite agent.

  Usage:

      # Start a runner — owner_user_id required for RLS
      AgentRunnerSupervisor.start_agent(agent.id, owner_user_id)

      # Stop a runner (e.g. when agent is paused)
      AgentRunnerSupervisor.stop_agent(agent.id)

      # Restart all active agents at boot (uses SECURITY DEFINER SQL to bypass RLS)
      AgentRunnerSupervisor.restart_active_agents()
  """

  use DynamicSupervisor

  require Logger

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Kite.AgentRunner

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start an AgentRunner for the given agent_id with its org owner's user_id."
  def start_agent(agent_id, owner_user_id \\ nil) do
    cond do
      runners_disabled?() ->
        Logger.info(
          "AgentRunnerSupervisor: KAH_AGENT_RUNNERS_DISABLED set — not starting runner for agent #{agent_id}"
        )

        {:ok, :disabled}

      AgentRunner.running?(agent_id) ->
        Logger.info("AgentRunnerSupervisor: runner already running for agent #{agent_id}")
        {:ok, :already_running}

      true ->
        resolved_owner = owner_user_id || Repo.owner_user_id_for_agent(agent_id)
        child_spec = {AgentRunner, [agent_id: agent_id, owner_user_id: resolved_owner]}
        DynamicSupervisor.start_child(__MODULE__, child_spec)
    end
  end

  # Emergency circuit breaker. Set the Fly secret
  # `KAH_AGENT_RUNNERS_DISABLED=1` and restart the machine to halt
  # all per-agent ticks (the prime suspect for the residual DB-pool
  # burst pattern after the every-minute crons were already disabled).
  # No code redeploy needed to flip — env var only.
  defp runners_disabled? do
    case System.get_env("KAH_AGENT_RUNNERS_DISABLED") do
      "1" -> true
      "true" -> true
      _ -> false
    end
  end

  @doc "Stop the AgentRunner for the given agent_id."
  def stop_agent(agent_id) do
    AgentRunner.stop(agent_id)
  end

  @doc """
  Called at startup — starts runners for all agents currently in 'active' status.
  Uses Repo.active_agents_with_owners/0 (SECURITY DEFINER) to bypass RLS at boot
  when no user context is available.
  """
  def restart_active_agents do
    pairs = Repo.active_agents_with_owners()
    Logger.info("AgentRunnerSupervisor: restarting #{length(pairs)} active agent runner(s)")

    Enum.each(pairs, fn {agent_id, owner_user_id} ->
      start_agent(agent_id, owner_user_id)
    end)
  end
end
