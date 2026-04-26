defmodule KiteAgentHubWeb.WorkspaceLive do
  @moduledoc """
  Workspace management tab for the Settings area.

  Lists the authenticated user's workspaces (organizations) and provides
  a form to create new ones. Wires the web UI up to the existing
  `KiteAgentHub.Orgs.create_org_for_user/2` backend which was
  previously only callable from seeds/console.

  Mounted at `/users/settings/workspace` — authenticated route.
  """
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Repo}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:org_cards, org_cards(user))
     |> assign(:form, to_form(%{"name" => ""}, as: :workspace))
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("create_workspace", %{"workspace" => %{"name" => name}}, socket) do
    user = socket.assigns.current_scope.user
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, :error, "Workspace name is required.")}
    else
      case Orgs.create_org_for_user(user, %{"name" => name}) do
        {:ok, _org} ->
          {:noreply,
           socket
           |> assign(:org_cards, org_cards(user))
           |> assign(:form, to_form(%{"name" => ""}, as: :workspace))
           |> assign(:error, nil)
           |> put_flash(:info, "Workspace '#{name}' created.")}

        {:error, _} ->
          {:noreply, assign(socket, :error, "Failed to create workspace.")}
      end
    end
  end

  @impl true
  def handle_event(
        "toggle_collective_intelligence",
        %{"org_id" => org_id, "enabled" => enabled},
        socket
      ) do
    user = socket.assigns.current_scope.user
    enable? = enabled == "true"

    case Orgs.update_collective_intelligence(user, org_id, enable?) do
      {:ok, _org} ->
        message =
          if enable?,
            do: "Kite Collective Intelligence enabled for this workspace.",
            else:
              "Kite Collective Intelligence disabled and prior anonymized contributions purged."

        {:noreply,
         socket
         |> assign(:org_cards, org_cards(user))
         |> put_flash(:info, message)}

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:org_cards, org_cards(user))
         |> put_flash(:error, "Only workspace owners and admins can change this setting.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:org_cards, org_cards(user))
         |> put_flash(:error, "Could not update Kite Collective Intelligence.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <KiteAgentHubWeb.SettingsNav.render active={:workspace} />

        <div class="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-10 space-y-6">
          <%!-- Appearance / theme --%>
          <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
            <div class="flex items-center justify-between gap-4 flex-wrap">
              <div>
                <h2 class="text-sm font-black text-white uppercase tracking-widest mb-1">
                  Appearance
                </h2>
                <p class="text-xs text-gray-500">
                  System follows your OS, or pick light or dark explicitly. Saved on this device.
                </p>
              </div>
              <Layouts.theme_toggle />
            </div>
          </div>

          <%!-- Workspaces list --%>
          <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
            <h2 class="text-sm font-black text-white uppercase tracking-widest mb-1">
              Your Workspaces
            </h2>
            <p class="text-xs text-gray-500 mb-5">
              Workspaces group your agents, trades, API credentials, and shared intelligence settings.
            </p>

            <%= if @org_cards == [] do %>
              <p class="text-xs text-gray-600">No workspaces yet. Create one below.</p>
            <% else %>
              <div class="space-y-2">
                <%= for %{org: org, can_manage?: can_manage?} <- @org_cards do %>
                  <div class="rounded-xl border border-white/5 bg-white/[0.02] px-4 py-4 space-y-4">
                    <div class="flex items-start justify-between gap-4">
                      <div>
                        <p class="text-sm font-bold text-white">{org.name}</p>
                        <p class="text-[10px] text-gray-600 font-mono">{org.slug}</p>
                      </div>
                      <div class={[
                        "rounded-full border px-3 py-1 text-[10px] font-black uppercase tracking-widest",
                        org.collective_intelligence_enabled &&
                          "border-[#22c55e]/40 bg-[#22c55e]/10 text-[#86efac]",
                        !org.collective_intelligence_enabled &&
                          "border-white/10 bg-white/[0.03] text-gray-500"
                      ]}>
                        {if org.collective_intelligence_enabled, do: "KCI On", else: "KCI Off"}
                      </div>
                    </div>

                    <div class="rounded-xl border border-[#22c55e]/15 bg-[#22c55e]/[0.03] p-4">
                      <div class="flex items-start justify-between gap-4 flex-wrap">
                        <div class="max-w-xl">
                          <h3 class="text-xs font-black text-white uppercase tracking-widest">
                            Kite Collective Intelligence
                          </h3>
                          <p class="mt-2 text-xs text-gray-400 leading-relaxed">
                            Opt in to let agents in this workspace use anonymized, bucketed lessons from terminal trade outcomes. KAH does not store raw chats, broker credentials, user IDs, agent IDs, or exact trade IDs in the shared learning table.
                          </p>
                          <p class="mt-2 text-[10px] text-gray-600 leading-relaxed">
                            Turning this off purges this workspace's prior anonymized contributions and stops future contribution or use.
                          </p>
                        </div>

                        <form phx-submit="toggle_collective_intelligence">
                          <input type="hidden" name="org_id" value={org.id} />
                          <input
                            type="hidden"
                            name="enabled"
                            value={if org.collective_intelligence_enabled, do: "false", else: "true"}
                          />
                          <button
                            type="submit"
                            disabled={!can_manage?}
                            class={[
                              "px-4 py-2 rounded-xl text-xs font-black uppercase tracking-widest transition-colors",
                              org.collective_intelligence_enabled &&
                                "bg-white/10 text-white hover:bg-white/15",
                              !org.collective_intelligence_enabled &&
                                "bg-[#22c55e] text-black hover:bg-[#86efac]",
                              !can_manage? && "opacity-50 cursor-not-allowed"
                            ]}
                          >
                            {if org.collective_intelligence_enabled, do: "Disable", else: "Enable"}
                          </button>
                        </form>
                      </div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Create workspace --%>
          <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
            <h2 class="text-sm font-black text-white uppercase tracking-widest mb-1">
              Create New Workspace
            </h2>
            <p class="text-xs text-gray-500 mb-5">
              Add another workspace to separate agents or teams.
            </p>

            <.form for={@form} phx-submit="create_workspace" class="space-y-4">
              <div>
                <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                  Workspace Name
                </label>
                <input
                  type="text"
                  name="workspace[name]"
                  placeholder="e.g., Prop Desk, Personal Alpha"
                  autocomplete="off"
                  class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
                />
              </div>
              <%= if @error do %>
                <p class="text-xs text-red-400">{@error}</p>
              <% end %>
              <button
                type="submit"
                phx-disable-with="Creating..."
                class="px-5 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors"
              >
                Create Workspace
              </button>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp org_cards(user) do
    orgs =
      case Repo.with_user(user.id, fn -> Orgs.list_orgs_for_user(user.id) end) do
        {:ok, orgs} -> orgs
        _ -> []
      end

    orgs
    |> Enum.map(fn org ->
      %{org: org, can_manage?: Orgs.can_manage_org?(user.id, org.id)}
    end)
  end
end
