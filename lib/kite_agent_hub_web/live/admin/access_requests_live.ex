defmodule KiteAgentHubWeb.Admin.AccessRequestsLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.Accounts.{Invites, UserNotifier}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:filter, "pending")
     |> assign(:newly_minted, nil)
     |> load_requests()}
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:filter, status)
     |> load_requests()}
  end

  def handle_event("generate", %{"id" => id}, socket) do
    req = Invites.get_access_request!(id)
    admin = socket.assigns.current_scope.user

    case Invites.generate_code(req, admin) do
      {:ok, _invite, plaintext} ->
        send_invite_email(req.email, plaintext)

        {:noreply,
         socket
         |> assign(:newly_minted, %{email: req.email, code: plaintext})
         |> put_flash(:info, "Code generated and emailed to #{req.email}.")
         |> load_requests()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not generate code. Try again.")}
    end
  end

  def handle_event("reject", %{"id" => id}, socket) do
    req = Invites.get_access_request!(id)
    admin = socket.assigns.current_scope.user

    KiteAgentHub.Accounts.AccessRequest.status_changeset(req, "rejected", admin.id)
    |> KiteAgentHub.Repo.update()

    {:noreply,
     socket
     |> put_flash(:info, "Request rejected.")
     |> load_requests()}
  end

  def handle_event("dismiss_minted", _, socket) do
    {:noreply, assign(socket, :newly_minted, nil)}
  end

  defp load_requests(socket) do
    assign(socket, :requests, Invites.list_access_requests(status: socket.assigns.filter))
  end

  defp send_invite_email(email, plaintext) do
    base = Application.get_env(:kite_agent_hub, :app_base_url, "https://kiteagenthub.com")

    Task.Supervisor.start_child(KiteAgentHub.TaskSupervisor, fn ->
      UserNotifier.deliver_invite_code(email, plaintext, base)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-gray-950 text-white px-6 py-10">
        <div class="max-w-5xl mx-auto">
          <h1 class="text-2xl font-black tracking-tight mb-6">Access requests</h1>

          <div class="flex gap-2 mb-6">
            <%= for status <- ~w(pending approved rejected) do %>
              <button
                phx-click="filter"
                phx-value-status={status}
                class={[
                  "px-3 py-1.5 rounded-lg text-xs font-semibold uppercase tracking-wider transition-all",
                  if(@filter == status,
                    do: "bg-violet-600 text-white",
                    else: "bg-white/[0.07] text-gray-400 hover:bg-white/[0.12]"
                  )
                ]}
              >
                {status}
              </button>
            <% end %>
          </div>

          <%= if @newly_minted do %>
            <div class="rounded-xl bg-violet-500/10 border border-violet-500/40 p-5 mb-6">
              <div class="flex items-center justify-between">
                <div>
                  <p class="text-xs uppercase tracking-wider text-violet-300 font-semibold mb-1">
                    Code generated for {@newly_minted.email}
                  </p>
                  <code class="text-lg font-mono text-white tracking-wide select-all">
                    {@newly_minted.code}
                  </code>
                  <p class="text-xs text-gray-400 mt-2">
                    14-day expiry. Email already sent. Copy if you want to relay manually.
                  </p>
                </div>
                <button
                  phx-click="dismiss_minted"
                  class="text-gray-400 hover:text-white text-2xl leading-none"
                >
                  &times;
                </button>
              </div>
            </div>
          <% end %>

          <div class="rounded-2xl bg-gray-900/95 border border-white/15 overflow-hidden">
            <table class="w-full text-sm">
              <thead class="bg-white/[0.04]">
                <tr class="text-left text-xs uppercase tracking-wider text-gray-400">
                  <th class="px-5 py-3">Submitted</th>
                  <th class="px-5 py-3">Name / Email</th>
                  <th class="px-5 py-3">Notes</th>
                  <th class="px-5 py-3 text-right">Actions</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-white/10">
                <%= for req <- @requests do %>
                  <tr class="hover:bg-white/[0.02]">
                    <td class="px-5 py-4 text-gray-400 whitespace-nowrap">
                      {Calendar.strftime(req.inserted_at, "%b %-d, %H:%M")}
                    </td>
                    <td class="px-5 py-4">
                      <div class="font-semibold text-white">{req.name}</div>
                      <div class="text-xs text-gray-400">{req.email}</div>
                    </td>
                    <td class="px-5 py-4 text-gray-300 max-w-md">
                      <span class="line-clamp-3">{req.notes || "—"}</span>
                    </td>
                    <td class="px-5 py-4 text-right whitespace-nowrap">
                      <%= if @filter == "pending" do %>
                        <button
                          phx-click="generate"
                          phx-value-id={req.id}
                          data-confirm={"Generate invite code for #{req.email}?"}
                          class="px-3 py-1.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white text-xs font-semibold transition-colors"
                        >
                          Generate code
                        </button>
                        <button
                          phx-click="reject"
                          phx-value-id={req.id}
                          data-confirm={"Reject #{req.email}?"}
                          class="px-3 py-1.5 rounded-lg bg-white/[0.07] hover:bg-red-500/20 text-gray-300 hover:text-red-300 text-xs font-semibold transition-colors ml-2"
                        >
                          Reject
                        </button>
                      <% else %>
                        <span class="text-xs text-gray-500 capitalize">{req.status}</span>
                      <% end %>
                    </td>
                  </tr>
                <% end %>
                <%= if @requests == [] do %>
                  <tr>
                    <td colspan="4" class="px-5 py-12 text-center text-gray-500 text-sm">
                      No {@filter} requests.
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
