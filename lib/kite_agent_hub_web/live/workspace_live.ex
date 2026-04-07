defmodule KiteAgentHubWeb.WorkspaceLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.Orgs

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    orgs = Orgs.list_orgs_for_user(user.id)

    {:ok,
     socket
     |> assign(:orgs, orgs)
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
          orgs = Orgs.list_orgs_for_user(user.id)

          {:noreply,
           socket
           |> assign(:orgs, orgs)
           |> assign(:form, to_form(%{"name" => ""}, as: :workspace))
           |> assign(:error, nil)
           |> put_flash(:info, "Workspace '#{name}' created.")}

        {:error, _} ->
          {:noreply, assign(socket, :error, "Failed to create workspace.")}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <%!-- Nav --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center gap-4">
            <.link
              navigate={~p"/dashboard"}
              class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
            >
              <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Dashboard
            </.link>
            <span class="text-gray-700">|</span>
            <h1 class="text-sm font-black text-white uppercase tracking-widest">Settings</h1>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/60 px-4 sm:px-6 lg:px-8">
          <nav class="flex gap-1 max-w-2xl mx-auto">
            <.link
              navigate={~p"/users/settings"}
              class="px-4 py-3 text-xs font-black uppercase tracking-widest text-gray-500 hover:text-white border-b-2 border-transparent hover:border-white/20 transition-all"
            >
              Account
            </.link>
            <.link
              navigate={~p"/users/settings/api-keys"}
              class="px-4 py-3 text-xs font-black uppercase tracking-widest text-gray-500 hover:text-white border-b-2 border-transparent hover:border-white/20 transition-all"
            >
              API Keys
            </.link>
            <.link
              navigate={~p"/users/settings/workspace"}
              class="px-4 py-3 text-xs font-black uppercase tracking-widest text-white border-b-2 border-white"
            >
              Workspace
            </.link>
          </nav>
        </div>

        <div class="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-10 space-y-6">
          <%!-- Workspaces list --%>
          <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
            <h2 class="text-sm font-black text-white uppercase tracking-widest mb-1">Your Workspaces</h2>
            <p class="text-xs text-gray-500 mb-5">Workspaces group your agents, trades, and API credentials.</p>

            <%= if @orgs == [] do %>
              <p class="text-xs text-gray-600">No workspaces yet. Create one below.</p>
            <% else %>
              <div class="space-y-2">
                <%= for org <- @orgs do %>
                  <div class="flex items-center justify-between rounded-xl border border-white/5 bg-white/[0.02] px-4 py-3">
                    <div>
                      <p class="text-sm font-bold text-white">{org.name}</p>
                      <p class="text-[10px] text-gray-600 font-mono">{org.slug}</p>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Create workspace --%>
          <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
            <h2 class="text-sm font-black text-white uppercase tracking-widest mb-1">Create New Workspace</h2>
            <p class="text-xs text-gray-500 mb-5">Add another workspace to separate agents or teams.</p>

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
end
