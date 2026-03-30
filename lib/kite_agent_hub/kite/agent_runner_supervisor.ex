defmodule KiteAgentHub.Kite.AgentRunnerSupervisor do
  @moduledoc """
  DynamicSupervisor that manages one AgentRunner per active Kite agent.

  Usage:

      # Start a runner for an agent
      AgentRunnerSupervisor.start_agent(agent.id)

      # Stop a runner (e.g. when agent is paused)
      AgentRunnerSupervisor.stop_agent(agent.id)

      # Restart all active agents (called from Application.start)
      AgentRunnerSupervisor.restart_active_agents()
  """

  use DynamicSupervisor

  require Logger

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Kite.AgentRunner

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start an AgentRunner for the given agent_id."
  def start_agent(agent_id, opts \\ []) do
    if AgentRunner.running?(agent_id) do
      Logger.info("AgentRunnerSupervisor: runner already running for agent #{agent_id}")
      {:ok, :already_running}
    else
      child_spec = {AgentRunner, Keyword.merge([agent_id: agent_id], opts)}
      DynamicSupervisor.start_child(__MODULE__, child_spec)
    end
  end

  @doc "Stop the AgentRunner for the given agent_id."
  def stop_agent(agent_id) do
    AgentRunner.stop(agent_id)
  end

  @doc "Called at startup — starts runners for all agents currently in 'active' status."
  def restart_active_agents do
    agents = Trading.list_all_active_agents()
    Logger.info("AgentRunnerSupervisor: restarting #{length(agents)} active agent runner(s)")

    Enum.each(agents, fn agent ->
      start_agent(agent.id)
    end)
  end
end
