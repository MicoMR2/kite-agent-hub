defmodule KiteAgentHubWeb.TradesLive do
  use KiteAgentHubWeb, :live_view

  require Logger
  alias KiteAgentHub.{Trading, Orgs}

  @page_size 25

  # Hard whitelist for sortable columns and filter values. User input
  # from `phx-value-col` / `phx-value-platform` is matched against
  # these atoms before being passed to Ecto's `order_by` or `where`.
  # Anything off-list is silently ignored — never raw input to the DB.
  @sort_whitelist ~w[inserted_at fill_price contracts platform status action market notional_usd]a
  @platform_whitelist ~w[all alpaca kalshi polymarket oanda oanda_practice forex]

  @impl true
  def mount(_params, _session, socket) do
    # Mount hardening (kah_lv_rescue): every DB call must rescue, or
    # a transient `DBConnection.ConnectionError` during a pool burst
    # crashes the LV process and Phoenix mount-loops the user.
    {org, agents} =
      try do
        org = Orgs.get_org_for_user(socket.assigns.current_scope.user.id)
        agents = if org, do: Trading.list_agents(org.id), else: []
        {org, agents}
      rescue
        e ->
          Logger.warning("TradesLive mount DB read failed — #{Exception.message(e)}")
          {nil, []}
      end

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:agents, agents)
     |> assign(:selected_agent, nil)
     |> assign(:trades, [])
     |> assign(:status_filter, "all")
     |> assign(:platform_filter, "all")
     |> assign(:sort_by, :inserted_at)
     |> assign(:sort_dir, :desc)
     |> assign(:page, 1)
     |> assign(:has_more, false)}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id} = params, _uri, socket) do
    case safe_get_agent(agent_id) do
      nil ->
        # Stale/invalid agent_id (or DB pool busy). Bounce to /trades
        # without crashing the LV; user retries when the URL clears.
        {:noreply, push_patch(socket, to: ~p"/trades")}

      agent ->
        status = params["status"] || "all"

        if is_nil(socket.assigns.selected_agent) or socket.assigns.selected_agent.id != agent_id do
          if connected?(socket) do
            Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{agent_id}")
          end
        end

        trades =
          try do
            load_trades(agent_id, status, 1)
          rescue
            _ -> []
          end

        {:noreply,
         socket
         |> assign(:selected_agent, agent)
         |> assign(:status_filter, status)
         |> assign(:trades, trades)
         |> assign(:page, 1)
         |> assign(:has_more, length(trades) == @page_size)}
    end
  end

  defp safe_get_agent(agent_id) do
    Trading.get_agent!(agent_id)
  rescue
    _ -> nil
  end

  def handle_params(_params, _uri, socket) do
    # No agent selected — pick first if available
    case socket.assigns.agents do
      [first | _] ->
        {:noreply, push_patch(socket, to: ~p"/trades?agent_id=#{first.id}")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    agent_id = socket.assigns.selected_agent.id

    {:noreply, push_patch(socket, to: ~p"/trades?agent_id=#{agent_id}&status=#{status}")}
  end

  def handle_event("filter_platform", %{"platform" => platform}, socket)
      when platform in @platform_whitelist do
    socket =
      socket
      |> assign(:platform_filter, platform)
      |> assign(:page, 1)
      |> reload_trades_with_current_filters()

    {:noreply, socket}
  end

  def handle_event("filter_platform", _params, socket), do: {:noreply, socket}

  def handle_event("sort", %{"col" => col}, socket) do
    col_atom = String.to_existing_atom(col)

    if col_atom in @sort_whitelist do
      new_dir =
        cond do
          socket.assigns.sort_by == col_atom and socket.assigns.sort_dir == :desc -> :asc
          socket.assigns.sort_by == col_atom and socket.assigns.sort_dir == :asc -> :desc
          true -> :desc
        end

      {:noreply,
       socket
       |> assign(:sort_by, col_atom)
       |> assign(:sort_dir, new_dir)
       |> assign(:page, 1)
       |> reload_trades_with_current_filters()}
    else
      {:noreply, socket}
    end
  rescue
    # String.to_existing_atom raises if the atom is not interned —
    # treat that as an unknown column (out-of-whitelist) and ignore.
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    agent_id = socket.assigns.selected_agent.id

    new_trades = load_trades_for(socket, agent_id, next_page)

    {:noreply,
     socket
     |> assign(:trades, socket.assigns.trades ++ new_trades)
     |> assign(:page, next_page)
     |> assign(:has_more, length(new_trades) == @page_size)}
  end

  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/trades?agent_id=#{agent_id}")}
  end

  @impl true
  def handle_info({:trade_created, trade}, socket) do
    if trade.kite_agent_id == (socket.assigns.selected_agent && socket.assigns.selected_agent.id) do
      {:noreply, assign(socket, :trades, reload_visible_trades(socket, trade.kite_agent_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:trade_updated, updated}, socket) do
    trades = reload_visible_trades(socket, updated.kite_agent_id)

    {:noreply, assign(socket, :trades, trades)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Components ────────────────────────────────────────────────────────────────

  # Clickable column header for the trades table. Renders an arrow that
  # reflects the current sort direction when the column is active.
  # Column atoms are passed by call site (compile-time constants), so the
  # `phx-value-col` value is never user-controlled.
  attr :label, :string, required: true
  attr :col, :atom, required: true
  attr :classes, :string, required: true
  attr :sort_by, :atom, required: true
  attr :sort_dir, :atom, required: true

  defp sort_header(assigns) do
    ~H"""
    <th class={[@classes, "text-[10px] font-bold uppercase tracking-widest whitespace-nowrap"]}>
      <button
        phx-click="sort"
        phx-value-col={Atom.to_string(@col)}
        class={[
          "inline-flex items-center gap-1 transition-colors",
          if(@sort_by == @col, do: "text-white", else: "text-gray-500 hover:text-gray-300")
        ]}
        title={"Sort by " <> @label}
      >
        {@label}
        <span class={if(@sort_by == @col, do: "opacity-100", else: "opacity-0 group-hover:opacity-40")}>
          <%= cond do %>
            <% @sort_by == @col and @sort_dir == :desc -> %>↓
            <% @sort_by == @col and @sort_dir == :asc -> %>↑
            <% true -> %>↕
          <% end %>
        </span>
      </button>
    </th>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  # Legacy 3-arg load (still called by handle_params on agent switch — keeps
  # the existing status param flow intact).
  defp load_trades(agent_id, "all", page) do
    Trading.list_trades_with_display_pnl(agent_id,
      limit: @page_size,
      offset: (page - 1) * @page_size
    )
  end

  defp load_trades(agent_id, status, page) do
    Trading.list_trades_with_display_pnl(agent_id,
      status: status,
      limit: @page_size,
      offset: (page - 1) * @page_size
    )
  end

  # Filter-aware load used by sort + platform filter + load_more so they
  # respect the user's current sort and platform without going through
  # push_patch (these are stateful assigns, not URL state).
  defp load_trades_for(socket, agent_id, page) do
    opts = current_filter_opts(socket, page)
    Trading.list_trades_with_display_pnl(agent_id, opts)
  end

  defp current_filter_opts(socket, page) do
    [
      limit: @page_size,
      offset: (page - 1) * @page_size,
      order_by: socket.assigns.sort_by,
      order_dir: socket.assigns.sort_dir
    ]
    |> maybe_put(:status, socket.assigns.status_filter, "all")
    |> maybe_put(:platform, socket.assigns.platform_filter, "all")
  end

  defp maybe_put(opts, _key, sentinel, sentinel), do: opts
  defp maybe_put(opts, key, value, _sentinel), do: Keyword.put(opts, key, value)

  defp reload_trades_with_current_filters(socket) do
    agent_id = socket.assigns.selected_agent && socket.assigns.selected_agent.id

    if agent_id do
      trades = load_trades_for(socket, agent_id, 1)

      socket
      |> assign(:trades, trades)
      |> assign(:has_more, length(trades) == @page_size)
    else
      socket
    end
  end

  defp reload_visible_trades(socket, agent_id) do
    selected_id = socket.assigns.selected_agent && socket.assigns.selected_agent.id

    if selected_id == agent_id do
      limit = max(socket.assigns.page, 1) * @page_size

      opts =
        [
          limit: limit,
          offset: 0,
          order_by: socket.assigns.sort_by,
          order_dir: socket.assigns.sort_dir
        ]
        |> maybe_put(:status, socket.assigns.status_filter, "all")
        |> maybe_put(:platform, socket.assigns.platform_filter, "all")

      Trading.list_trades_with_display_pnl(agent_id, opts)
    else
      socket.assigns.trades
    end
  end

  defp status_classes("open"), do: "bg-blue-500/10 text-blue-400 ring-1 ring-blue-500/20"

  defp status_classes("settled"),
    do: "bg-emerald-500/10 text-emerald-400 ring-1 ring-emerald-500/20"

  defp status_classes("failed"), do: "bg-red-500/10 text-red-400 ring-1 ring-red-500/20"
  defp status_classes("cancelled"), do: "bg-gray-500/10 text-gray-400 ring-1 ring-gray-500/20"
  defp status_classes(_), do: "bg-gray-500/10 text-gray-500"

  defp pnl_class(nil), do: "text-gray-600"

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :gt -> "text-emerald-400 font-bold"
      :lt -> "text-red-400 font-bold"
      _ -> "text-gray-500"
    end
  end

  defp format_pnl(nil), do: "—"

  defp format_pnl(pnl) do
    val = Decimal.to_float(pnl)

    if val >= 0,
      do: "+$#{:erlang.float_to_binary(val, decimals: 2)}",
      else: "-$#{:erlang.float_to_binary(abs(val), decimals: 2)}"
  end

  defp format_notional(nil), do: "—"
  defp format_notional(n), do: "$#{Decimal.round(n, 2)}"

  # Failed/cancelled trades sometimes arrive with a nil platform value
  # before the broker adapter has had a chance to tag the record. Show
  # "Unknown" rather than defaulting to "Kite" — the latter falsely
  # implies an on-chain trade and confused users (Mico 9894).
  defp platform_label(nil), do: "Unknown"
  defp platform_label(platform), do: platform |> String.replace("_", " ") |> String.upcase()

  defp platform_pill_class(platform) do
    "kah-platform-pill #{platform_color_class(platform)}"
  end

  defp platform_color_class(platform) when is_binary(platform) do
    case String.downcase(platform) do
      "alpaca" -> "kah-platform-alpaca"
      "kalshi" -> "kah-platform-kalshi"
      "polymarket" -> "kah-platform-polymarket"
      "oanda" -> "kah-platform-forex"
      "oanda_practice" -> "kah-platform-forex"
      "forex" -> "kah-platform-forex"
      _ -> "kah-platform-kite"
    end
  end

  defp platform_color_class(_), do: "kah-platform-kite"

  defp attestation_url(hash, chain_id) do
    base = KiteAgentHub.Kite.Contracts.explorer_url(chain_id || KiteAgentHub.Kite.ChainId.default())
    base <> "/tx/" <> (hash || "")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <%!-- Nav --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center justify-between">
            <div class="flex items-center gap-4">
              <.link
                navigate={~p"/dashboard"}
                class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
              >
                <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Dashboard
              </.link>
              <span class="text-gray-700 hidden sm:block">|</span>
              <h1 class="text-sm font-black text-white uppercase tracking-widest hidden sm:block">
                Trade History
              </h1>
            </div>
            <div class="flex flex-wrap gap-2">
              <%= for {label, val} <- [{"All", "all"}, {"Open", "open"}, {"Settled", "settled"}, {"Failed", "failed"}] do %>
                <button
                  phx-click="filter"
                  phx-value-status={val}
                  class={[
                    "px-4 py-1.5 rounded-xl border text-[10px] sm:text-xs font-bold uppercase tracking-widest transition-all",
                    @status_filter == val &&
                      "bg-white/10 border-white/20 text-white shadow-[0_0_15px_rgba(255,255,255,0.05)]",
                    @status_filter != val &&
                      "bg-transparent border-transparent text-gray-500 hover:text-white hover:bg-white/5"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <div class="w-full px-4 sm:px-6 lg:px-8 py-6 flex flex-col md:flex-row gap-6">
          <%!-- Agent Sidebar --%>
          <div class="w-full md:w-48 lg:w-72 shrink-0 space-y-4">
            <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest px-2">
              Agents
            </h2>
            <div class="space-y-2">
              <%= for agent <- @agents do %>
                <button
                  phx-click="select_agent"
                  phx-value-id={agent.id}
                  class={[
                    "w-full text-left px-4 py-4 rounded-xl border transition-all group",
                    @selected_agent && @selected_agent.id == agent.id &&
                      "border-white/20 bg-white/[0.05] shadow-[0_0_15px_rgba(255,255,255,0.02)]",
                    (!@selected_agent || @selected_agent.id != agent.id) &&
                      "border-white/5 bg-white/[0.01] hover:border-white/10 hover:bg-white/[0.03]"
                  ]}
                >
                  <div class="flex items-center justify-between gap-2">
                    <span class={[
                      "text-sm font-bold truncate tracking-wide transition-colors",
                      @selected_agent && @selected_agent.id == agent.id && "text-white",
                      (!@selected_agent || @selected_agent.id != agent.id) &&
                        "text-gray-400 group-hover:text-gray-200"
                    ]}>
                      {agent.name}
                    </span>
                    <span class={[
                      "w-2 h-2 rounded-full shrink-0",
                      agent.status == "active" && "bg-[#22c55e] shadow-[0_0_8px_#22c55e]",
                      agent.status == "paused" && "bg-yellow-400",
                      agent.status == "pending" && "bg-gray-500",
                      agent.status == "error" && "bg-[#ef4444]"
                    ]}>
                    </span>
                  </div>
                  <p class="text-[10px] text-gray-500 uppercase tracking-widest font-bold mt-2">
                    {agent.status}
                  </p>
                </button>
              <% end %>
            </div>
          </div>

          <%!-- Trade Table --%>
          <div class="flex-1 min-w-0">
            <%!-- Active Agent banner (Mico 9894 #3) — makes it unmissable which
            agent's trades are on screen, especially when scrolling the table
            past the sidebar. --%>
            <%= if @selected_agent do %>
              <div class="mb-4 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 rounded-2xl border border-emerald-500/30 bg-gradient-to-r from-emerald-500/[0.08] to-emerald-500/[0.01] px-6 py-4 shadow-[0_0_20px_rgba(34,197,94,0.08)]">
                <div class="min-w-0">
                  <p class="text-[10px] text-emerald-400 font-bold uppercase tracking-widest mb-1">
                    Viewing trades for
                  </p>
                  <div class="flex flex-wrap items-center gap-3">
                    <h2 class="text-2xl sm:text-3xl font-black text-white tracking-tight truncate">
                      {@selected_agent.name}
                    </h2>
                    <span class={[
                      "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full border text-[10px] font-bold uppercase tracking-widest",
                      @selected_agent.status == "active" &&
                        "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e]",
                      @selected_agent.status == "paused" &&
                        "bg-yellow-500/10 border-yellow-500/20 text-yellow-400",
                      @selected_agent.status == "pending" &&
                        "bg-gray-500/10 border-gray-500/20 text-gray-400",
                      @selected_agent.status == "error" &&
                        "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]"
                    ]}>
                      <span class={[
                        "w-1.5 h-1.5 rounded-full",
                        @selected_agent.status == "active" &&
                          "bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse",
                        @selected_agent.status == "paused" && "bg-yellow-400",
                        @selected_agent.status == "pending" && "bg-gray-500",
                        @selected_agent.status == "error" && "bg-[#ef4444]"
                      ]}>
                      </span>
                      {@selected_agent.status}
                    </span>
                    <%= if @selected_agent.agent_type do %>
                      <span class={[
                        "text-[10px] px-2 py-0.5 rounded border uppercase tracking-widest font-bold",
                        case @selected_agent.agent_type do
                          "trading" -> "bg-emerald-500/10 border-emerald-500/20 text-emerald-400"
                          "research" -> "bg-blue-500/10 border-blue-500/20 text-blue-400"
                          _ -> "bg-purple-500/10 border-purple-500/20 text-purple-400"
                        end
                      ]}>
                        {@selected_agent.agent_type}
                      </span>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
            <%!-- Platform filter (Mico 9894 #2) — server-side whitelist enforced
            in handle_event before any Ecto where call. --%>
            <div class="mb-3 flex flex-wrap items-center gap-2">
              <span class="text-[10px] text-gray-500 font-bold uppercase tracking-widest">
                Platform
              </span>
              <%= for {label, val} <- [{"All", "all"}, {"Alpaca", "alpaca"}, {"Kalshi", "kalshi"}, {"Polymarket", "polymarket"}, {"Forex", "oanda"}] do %>
                <button
                  phx-click="filter_platform"
                  phx-value-platform={val}
                  class={[
                    "px-3 py-1 rounded-lg border text-[10px] font-bold uppercase tracking-widest transition-all",
                    @platform_filter == val &&
                      "bg-white/10 border-white/20 text-white shadow-[0_0_10px_rgba(255,255,255,0.04)]",
                    @platform_filter != val &&
                      "bg-transparent border-white/5 text-gray-500 hover:text-white hover:bg-white/5"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md overflow-x-auto">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-white/10 bg-black/20">
                    <.sort_header label="Market" col={:market} classes="text-left px-3 py-3 sm:px-6 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <.sort_header label="Platform" col={:platform} classes="hidden lg:table-cell text-left px-3 py-3 sm:px-4 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <.sort_header label="Action" col={:action} classes="text-left px-3 py-3 sm:px-4 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <.sort_header label="Qty" col={:contracts} classes="text-right px-3 py-3 sm:px-4 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <.sort_header label="Fill" col={:fill_price} classes="text-right px-3 py-3 sm:px-4 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <.sort_header label="Notional" col={:notional_usd} classes="hidden sm:table-cell text-right px-4 py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <th class="text-right px-3 py-3 sm:px-4 sm:py-4 text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                      P&L
                    </th>
                    <.sort_header label="Status" col={:status} classes="text-center px-3 py-3 sm:px-4 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                    <th class="hidden sm:table-cell text-center px-4 py-4 text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                      Chain
                    </th>
                    <.sort_header label="Time" col={:inserted_at} classes="hidden md:table-cell text-right px-3 py-3 sm:px-6 sm:py-4" sort_by={@sort_by} sort_dir={@sort_dir} />
                  </tr>
                </thead>
                <tbody class="divide-y divide-white/5">
                  <%= if @trades == [] do %>
                    <tr>
                      <td colspan="10" class="px-6 py-20 text-center">
                        <div class="flex flex-col items-center gap-4">
                          <div class="w-12 h-12 rounded-xl border border-white/5 bg-white/[0.02] flex items-center justify-center">
                            <.icon
                              name="hero-chart-bar"
                              class="w-6 h-6 text-gray-600"
                            />
                          </div>
                          <p class="text-sm font-bold text-gray-400">No trades yet</p>
                        </div>
                      </td>
                    </tr>
                  <% else %>
                    <%= for trade <- @trades do %>
                      <tr class="hover:bg-white/[0.02] transition-colors group">
                        <td
                          class="px-3 py-3 sm:px-6 sm:py-4 font-black whitespace-nowrap text-white text-sm tracking-tight max-w-[14rem] truncate"
                          title={trade.market}
                        >
                          {truncate_market(trade.market)}
                        </td>
                        <td class="hidden lg:table-cell px-3 py-3 sm:px-4 sm:py-4 whitespace-nowrap">
                          <span class={platform_pill_class(trade.platform)}>
                            {platform_label(trade.platform)}
                          </span>
                        </td>
                        <td class="px-3 py-3 sm:px-4 sm:py-4 whitespace-nowrap">
                          <span class={[
                            "inline-flex px-2 py-1 rounded border text-[10px] font-black uppercase tracking-widest",
                            trade.action == "buy" &&
                              "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e] group-hover:bg-[#22c55e]/20",
                            trade.action == "sell" &&
                              "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444] group-hover:bg-[#ef4444]/20"
                          ]}>
                            {trade.action}
                          </span>
                        </td>
                        <td class="px-3 py-3 sm:px-4 sm:py-4 text-right tabular-nums text-gray-300 font-mono text-sm whitespace-nowrap">
                          {trade.contracts}
                        </td>
                        <td class="px-3 py-3 sm:px-4 sm:py-4 text-right tabular-nums font-mono text-sm text-gray-300 whitespace-nowrap">
                          ${trade.fill_price}
                        </td>
                        <td class="hidden sm:table-cell px-4 py-4 text-right tabular-nums font-mono text-sm text-gray-500 whitespace-nowrap">
                          {format_notional(trade.notional_usd)}
                        </td>
                        <td class={"px-3 py-3 sm:px-4 sm:py-4 text-right tabular-nums text-sm font-mono whitespace-nowrap #{pnl_class(trade.display_pnl)}"}>
                          {format_pnl(trade.display_pnl)}
                        </td>
                        <td class="px-3 py-3 sm:px-4 sm:py-4 text-center whitespace-nowrap">
                          <span class={"inline-flex px-2 py-1 rounded border text-[10px] font-bold uppercase tracking-widest #{status_classes(trade.status)}"}>
                            {trade.status}
                          </span>
                        </td>
                        <td class="hidden sm:table-cell px-4 py-4 text-center whitespace-nowrap">
                          <%= if trade.attestation_tx_hash do %>
                            <a
                              href={attestation_url(trade.attestation_tx_hash, @selected_agent && @selected_agent.chain_id)}
                              target="_blank"
                              rel="noopener noreferrer"
                              title={"Kite chain attestation: " <> trade.attestation_tx_hash}
                              class="inline-flex items-center gap-1 text-[10px] font-bold text-emerald-400 hover:text-emerald-300 uppercase tracking-widest transition-colors"
                            >
                              <svg
                                class="w-3 h-3"
                                fill="none"
                                viewBox="0 0 24 24"
                                stroke="currentColor"
                              >
                                <path
                                  stroke-linecap="round"
                                  stroke-linejoin="round"
                                  stroke-width="2"
                                  d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                                />
                              </svg>
                              Chain
                            </a>
                          <% else %>
                            <%= if trade.tx_hash && String.match?(trade.tx_hash, ~r/^0x[0-9a-fA-F]{64}$/) do %>
                              <a
                                href={attestation_url(trade.tx_hash, @selected_agent && @selected_agent.chain_id)}
                                target="_blank"
                                rel="noopener noreferrer"
                                title={"Kite intent transaction: " <> trade.tx_hash}
                                class="inline-flex items-center gap-1 text-[10px] font-bold text-blue-400 hover:text-blue-300 uppercase tracking-widest transition-colors"
                              >
                                <svg
                                  class="w-3 h-3"
                                  fill="none"
                                  viewBox="0 0 24 24"
                                  stroke="currentColor"
                                >
                                  <path
                                    stroke-linecap="round"
                                    stroke-linejoin="round"
                                    stroke-width="2"
                                    d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                                  />
                                </svg>
                                Tx
                              </a>
                            <% else %>
                              <span class="text-[10px] text-gray-700 font-mono">—</span>
                            <% end %>
                          <% end %>
                        </td>
                        <td class="hidden md:table-cell px-3 py-3 sm:px-6 sm:py-4 text-right text-xs text-gray-500 tabular-nums whitespace-nowrap font-mono tracking-widest">
                          <span
                            id={"trade-time-#{trade.id}"}
                            phx-hook="LocalTime"
                            data-iso={DateTime.to_iso8601(trade.inserted_at)}
                            data-format="datetime"
                          >
                            {Calendar.strftime(trade.inserted_at, "%b %d %H:%M")}
                          </span>
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>

              <%= if @has_more do %>
                <div class="px-6 py-5 border-t border-white/10 text-center bg-black/20">
                  <button
                    phx-click="load_more"
                    class="text-xs text-white hover:text-gray-300 font-bold uppercase tracking-widest transition-colors flex items-center justify-center gap-2 mx-auto"
                  >
                    Load Older Trades <span>↓</span>
                  </button>
                </div>
              <% end %>
            </div>

            <%= if trade = Enum.find(@trades, &(&1.reason)) do %>
              <div class="mt-6 rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                <div class="flex items-center gap-3 mb-3">
                  <div class="h-6 w-6 rounded border border-white/10 bg-white/[0.05] flex items-center justify-center">
                    <.icon name="hero-cpu-chip" class="w-3.5 h-3.5 text-gray-400" />
                  </div>
                  <h3 class="text-xs font-bold text-gray-500 uppercase tracking-widest">
                    Latest Signal Reasoning
                  </h3>
                </div>
                <p class="text-sm font-light text-gray-300 leading-relaxed font-mono">
                  > {trade.reason}
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
