defmodule KiteAgentHubWeb.HomeLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.Kite.VaultBalance

  @impl true
  def mount(_params, _session, socket) do
    # Bounded fetch — Task.async with 2s timeout inside the module so
    # the LV mount never blocks on Blockscout (CyberSec ask 2 / Phorari
    # note 3 on the vault balance widget).
    vault =
      try do
        VaultBalance.cached_or_fetch()
      rescue
        _ -> {:error, :crash}
      end

    {:ok, assign(socket, :vault_snapshot, vault)}
  end
end
