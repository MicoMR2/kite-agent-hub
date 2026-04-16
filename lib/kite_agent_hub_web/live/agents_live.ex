defmodule KiteAgentHubWeb.AgentsLive do
  @moduledoc """
  Settings > Agents tab. Lists every agent in the current user's org,
  plus inline edit (name/tags/bio), API-token rotation (shown once),
  and archive (soft-delete with cascade-cancel of open trades) —
  Phorari PR msg 6341, PR-B of the split agreed in msg 6347.

  All mutations flow through `KiteAgentHub.Trading` (backed by the
  API controller from PR-A) so the same RLS + whitelist enforcement
  covers both the LiveView and the REST surface.
  """
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Repo, Trading}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    org = Orgs.get_org_for_user(user.id)
    agents = if org, do: Trading.list_agents(org.id), else: []

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:agents, agents)
     |> assign(:editing_id, nil)
     |> assign(:form_errors, %{})
     |> assign(:revealed_token, nil)
     |> assign(:confirm_archive_id, nil)}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_id: id, form_errors: %{})}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, form_errors: %{})}
  end

  def handle_event("save", %{"id" => id} = params, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))
    attrs = %{
      "name" => params["name"],
      "bio" => params["bio"],
      "tags" => parse_tags(params["tags"])
    }

    case Repo.with_user(socket.assigns.current_scope.user.id, fn ->
           Trading.update_agent_profile(agent, attrs)
         end) do
      {:ok, {:ok, updated}} ->
        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, updated))
         |> assign(:editing_id, nil)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "Agent updated.")}

      {:ok, {:error, changeset}} ->
        {:noreply, assign(socket, :form_errors, errors_of(changeset))}
    end
  end

  def handle_event("rotate_token", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))

    case Repo.with_user(socket.assigns.current_scope.user.id, fn ->
           Trading.rotate_agent_api_token(agent)
         end) do
      {:ok, {:ok, updated}} ->
        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, updated))
         |> assign(:revealed_token, %{id: updated.id, token: updated.api_token})
         |> put_flash(:info, "API token rotated. Copy it now — it won't be shown again.")}

      {:ok, {:error, _}} ->
        {:noreply, put_flash(socket, :error, "Token rotation failed.")}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, revealed_token: nil)}
  end

  def handle_event("confirm_archive", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_archive_id: id)}
  end

  def handle_event("cancel_archive", _params, socket) do
    {:noreply, assign(socket, confirm_archive_id: nil)}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))

    case Repo.with_user(socket.assigns.current_scope.user.id, fn ->
           Trading.archive_agent(agent)
         end) do
      {:ok, {:ok, %{agent: archived, cancelled_count: n}}} ->
        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, archived))
         |> assign(:confirm_archive_id, nil)
         |> put_flash(
           :info,
           "#{archived.name} archived. #{n} open trade(s) auto-cancelled."
         )}

      {:ok, {:error, _}} ->
        {:noreply,
         socket
         |> assign(:confirm_archive_id, nil)
         |> put_flash(:error, "Archive failed.")}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp parse_tags(nil), do: []

  defp parse_tags(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(other) when is_list(other), do: other
  defp parse_tags(_), do: []

  defp replace_agent(agents, updated) do
    Enum.map(agents, fn a -> if a.id == updated.id, do: updated, else: a end)
  end

  defp errors_of(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, k ->
        opts |> Keyword.get(String.to_existing_atom(k), k) |> to_string()
      end)
    end)
  end

  # ── Render ────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-white">
        <KiteAgentHubWeb.SettingsNav.render active={:agents} />

        <div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-10 space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-sm font-black text-white uppercase tracking-widest">Agents</h2>
              <p class="text-xs text-gray-500 mt-0.5">
                Manage every agent in {(@org && @org.name) || "your workspace"} — edit profile, rotate API tokens, archive.
              </p>
            </div>
            <.link
              navigate={~p"/agents/new"}
              class="px-4 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors"
            >
              New Agent
            </.link>
          </div>

          <%= if @revealed_token do %>
            <div class="rounded-2xl border border-emerald-500/40 bg-emerald-500/5 p-5 space-y-2">
              <div class="flex items-center justify-between">
                <h3 class="text-xs font-black text-emerald-300 uppercase tracking-widest">
                  New API Token — copy it now
                </h3>
                <button
                  phx-click="dismiss_token"
                  class="text-[10px] font-bold uppercase tracking-widest text-gray-500 hover:text-white"
                >
                  Dismiss
                </button>
              </div>
              <p class="text-[11px] text-gray-400">
                This token is shown only once. Replace it in any scripts/clients using the previous token.
              </p>
              <code class="block font-mono text-xs text-emerald-200 break-all bg-black/40 rounded-xl p-3">
                {@revealed_token.token}
              </code>
            </div>
          <% end %>

          <%= if @agents == [] do %>
            <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-8 text-center">
              <p class="text-sm text-gray-500">
                No agents yet. Create one from the button above.
              </p>
            </div>
          <% end %>

          <div :for={agent <- @agents} class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
            <%= if @editing_id == agent.id do %>
              <form phx-submit="save" class="space-y-4">
                <input type="hidden" name="id" value={agent.id} />

                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Name
                  </label>
                  <input
                    type="text"
                    name="name"
                    value={agent.name}
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white focus:outline-none focus:border-white/30"
                  />
                  <p :if={err = get_in(@form_errors, [:name, Access.at(0)])} class="text-xs text-red-400 mt-1">{err}</p>
                </div>

                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Tags <span class="text-gray-600 normal-case tracking-normal">(comma-separated)</span>
                  </label>
                  <input
                    type="text"
                    name="tags"
                    value={Enum.join(agent.tags || [], ", ")}
                    placeholder="momentum, equities"
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
                  />
                  <p :if={err = get_in(@form_errors, [:tags, Access.at(0)])} class="text-xs text-red-400 mt-1">{err}</p>
                </div>

                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Bio
                  </label>
                  <textarea
                    name="bio"
                    rows="3"
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 resize-none"
                  >{agent.bio}</textarea>
                  <p :if={err = get_in(@form_errors, [:bio, Access.at(0)])} class="text-xs text-red-400 mt-1">{err}</p>
                </div>

                <div class="flex items-center gap-3">
                  <button
                    type="submit"
                    class="px-5 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100"
                  >
                    Save
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    class="px-5 py-2 rounded-xl border border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% else %>
              <div class="space-y-3">
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <h3 class="text-sm font-black text-white truncate">{agent.name}</h3>
                      <span class={[
                        "text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-full",
                        agent.status == "active" && "bg-emerald-500/10 text-emerald-400",
                        agent.status == "paused" && "bg-yellow-500/10 text-yellow-400",
                        agent.status == "archived" && "bg-gray-500/10 text-gray-500",
                        agent.status == "error" && "bg-red-500/10 text-red-400",
                        agent.status == "pending" && "bg-blue-500/10 text-blue-400"
                      ]}>
                        {agent.status}
                      </span>
                      <span class="text-[10px] font-bold uppercase tracking-widest text-gray-600">
                        {agent.agent_type}
                      </span>
                    </div>
                    <p class="text-[11px] text-gray-500 mt-0.5">
                      Workspace: {(@org && @org.name) || "—"}
                    </p>
                    <p :if={agent.bio} class="text-xs text-gray-400 mt-2">{agent.bio}</p>
                    <div :if={agent.tags && agent.tags != []} class="flex flex-wrap gap-1 mt-2">
                      <span
                        :for={tag <- agent.tags}
                        class="text-[10px] font-bold uppercase tracking-widest bg-white/5 border border-white/10 rounded-full px-2 py-0.5 text-gray-300"
                      >
                        {tag}
                      </span>
                    </div>
                  </div>
                  <div class="flex flex-col gap-1.5 shrink-0">
                    <button
                      :if={agent.status != "archived"}
                      phx-click="edit"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      Edit
                    </button>
                    <button
                      :if={agent.status != "archived"}
                      phx-click="rotate_token"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      Rotate Token
                    </button>
                    <button
                      :if={agent.status != "archived"}
                      phx-click="confirm_archive"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-red-500/30 text-[10px] font-bold uppercase tracking-widest text-red-400 hover:bg-red-500/10"
                    >
                      Archive
                    </button>
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-3 pt-3 border-t border-white/5 text-[11px]">
                  <div>
                    <span class="block text-[10px] font-bold text-gray-600 uppercase tracking-widest">Wallet</span>
                    <span class={[
                      "font-mono truncate block",
                      agent.wallet_address && "text-gray-400",
                      !agent.wallet_address && agent.agent_type == "trading" && "text-yellow-500",
                      !agent.wallet_address && agent.agent_type != "trading" && "text-gray-600"
                    ]}>
                      <%= cond do %>
                        <% agent.wallet_address -> %>
                          {agent.wallet_address}
                        <% agent.agent_type == "trading" -> %>
                          trading disabled — wallet not configured
                        <% true -> %>
                          n/a (non-trading agent)
                      <% end %>
                    </span>
                  </div>
                  <div>
                    <span class="block text-[10px] font-bold text-gray-600 uppercase tracking-widest">Vault</span>
                    <span class="font-mono truncate block text-gray-400">
                      {agent.vault_address || "—"}
                    </span>
                  </div>
                </div>

                <div :if={@confirm_archive_id == agent.id} class="mt-4 p-4 rounded-xl border border-red-500/30 bg-red-500/5 space-y-2">
                  <p class="text-xs text-red-300">
                    Archive <strong>{agent.name}</strong>? This stops the runner and auto-cancels every open trade on the broker book. Status flips to <strong>archived</strong>. The agent's history and attestations are preserved.
                  </p>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="archive"
                      phx-value-id={agent.id}
                      class="px-4 py-1.5 rounded-xl bg-red-500 text-white text-[10px] font-bold uppercase tracking-widest hover:bg-red-600"
                    >
                      Yes, archive
                    </button>
                    <button
                      phx-click="cancel_archive"
                      class="px-4 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
