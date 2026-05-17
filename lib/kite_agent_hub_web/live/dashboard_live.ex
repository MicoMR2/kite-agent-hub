defmodule KiteAgentHubWeb.DashboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Onboarding, Orgs, Trading, Chat, Polymarket, Oanda}

  require Logger
  alias KiteAgentHub.Kite.{RPC, EdgeScorer, PortfolioEdgeScorer}
  alias KiteAgentHub.TradingPlatforms.{AlpacaClient, KalshiClient}

  # Debounce interval for stats refresh triggered by trade broadcasts.
  # Multiple trades settling in quick succession only trigger one API
  # call instead of hammering Alpaca/Kalshi on every single event.
  @stats_debounce_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    try do
      do_mount(socket)
    rescue
      e ->
        Logger.error(
          "DashboardLive mount CRASHED: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        {:ok, assign_minimal_socket(socket)}
    catch
      kind, reason ->
        Logger.error("DashboardLive mount CAUGHT #{kind}: #{inspect(reason)}")
        {:ok, assign_minimal_socket(socket)}
    end
  end

  defp do_mount(socket) do
    user = socket.assigns.current_scope.user

    orgs =
      try do
        Orgs.list_orgs_for_user(user.id)
      rescue
        _ -> []
      end

    org = List.first(orgs)

    if org do
      try do
        Onboarding.provision_for_user(user, org)
      rescue
        e -> Logger.warning("Dashboard provisioning skipped: #{inspect(e)}")
      end
    end

    {agents, trades} =
      if org do
        agents =
          try do
            Trading.list_agents(org.id)
          rescue
            _ -> []
          end

        selected = List.first(agents)

        trades =
          if selected do
            try do
              Trading.list_trades(selected.id, limit: 20)
            rescue
              _ -> []
            end
          else
            []
          end

        {agents, trades}
      else
        {[], []}
      end

    stats = empty_broker_stats()

    selected_agent = List.first(agents)

    if connected?(socket) do
      try do
        if selected_agent do
          Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{selected_agent.id}")
          fetch_chain_data(selected_agent)
        end

        if org, do: Chat.subscribe(org.id)
        send(self(), :load_edge_scores)
        if org, do: send(self(), :load_broker_stats)
      rescue
        e -> Logger.warning("Dashboard mount connected block failed: #{inspect(e)}")
      end
    end

    chat_messages =
      try do
        if org do
          org.id
          |> Chat.list_messages(limit: 200)
          |> Enum.map(&sanitize_broadcast/1)
        else
          []
        end
      rescue
        _ -> []
      end

    socket =
      socket
      |> assign(:organization, org)
      |> assign(:agents, agents)
      |> assign(:selected_agent, selected_agent)
      |> assign(:pnl_stats, stats)
      |> assign(:wallet_balance_eth, nil)
      |> assign(:block_number, nil)
      |> assign(:vault_form, to_form(%{"vault_address" => ""}, as: :vault))
      |> assign(:active_tab, :overview)
      |> assign(:edge_scores, [])
      |> assign(:edge_scores_loading, connected?(socket))
      |> assign(:portfolio_scores, nil)
      |> assign(:alpaca_data, nil)
      |> assign(:alpaca_history, [])
      |> assign(:alpaca_history_base_value, nil)
      |> assign(:alpaca_period, "1M")
      |> assign(:kalshi_data, nil)
      |> assign(:kalshi_quick_trade_ticker, "")
      |> assign(:kalshi_quick_trade_units, "1")
      |> assign(:kalshi_quick_trade_side, "yes")
      |> assign(:kalshi_quick_trade_price, "1")
      |> assign(:kalshi_action_flash, nil)
      |> assign(:agent_log_entries, [])
      |> assign(:agent_log_subscribed_id, nil)
      |> assign(:alpaca_live_tick_enabled, false)
      |> assign(:alpaca_live_tick_status, :off)
      |> assign(:alpaca_live_tick_prices, %{})
      |> assign(:alpaca_live_tick_subscribed_symbols, [])
      |> assign(:wallet_txs, nil)
      |> assign(:wallet_tokens, nil)
      |> assign(:show_agent_context, false)
      |> assign(:agent_context_text, nil)
      |> assign(:agent_context_news, [])
      |> assign(:show_agent_token, false)
      |> assign(:show_option_a, false)
      |> assign(:show_option_b, false)
      |> assign(:show_option_c, false)
      |> assign(:portfolio_pnl_period, :all_time)
      |> assign(:attestation_count, attestation_count(selected_agent))
      |> assign(:recent_attestations, recent_attestations(selected_agent))
      |> assign(:all_attestations, [])
      |> assign(:polymarket_data, nil)
      |> assign(:polymarket_positions, [])
      |> assign(:polymarket_mode, safe_polymarket_mode())
      |> assign(:forex_positions, [])
      |> assign(:forex_nav_history, [])
      |> assign(:forex_fetching, false)
      |> assign(:forex_instruments, [])
      |> assign(:forex_loading, false)
      |> assign(:forex_provider, :none)
      |> assign(:forex_oanda_env, nil)
      |> assign(:forex_account, nil)
      |> assign(:forex_candles, [])
      |> assign(:forex_symbol, "EUR_USD")
      |> assign(:forex_pricing, nil)
      |> assign(:forex_pricing_by_instrument, %{})
      |> assign(:forex_open_trades, [])
      |> assign(:forex_recent_trades, [])
      |> assign(:forex_quick_trade_units, "1000")
      |> assign(:forex_action_flash, nil)
      |> assign(:forex_pending_trade, nil)
      |> assign(:forex_chart_price, "M")
      |> assign(:stats_refresh_timer, nil)
      |> assign(:chat_messages, chat_messages)
      |> stream(:trades, trades)

    {:ok, socket}
  end

  # Minimal socket so the dashboard renders SOMETHING instead of crash-looping.
  # Every assign that the template reads must have a safe default here.
  defp assign_minimal_socket(socket) do
    socket
    |> assign(:organization, nil)
    |> assign(:agents, [])
    |> assign(:selected_agent, nil)
    |> assign(:pnl_stats, empty_broker_stats())
    |> assign(:wallet_balance_eth, nil)
    |> assign(:block_number, nil)
    |> assign(:vault_form, to_form(%{"vault_address" => ""}, as: :vault))
    |> assign(:active_tab, :overview)
    |> assign(:edge_scores, [])
    |> assign(:edge_scores_loading, false)
    |> assign(:portfolio_scores, nil)
    |> assign(:alpaca_data, nil)
    |> assign(:alpaca_history, [])
    |> assign(:alpaca_history_base_value, nil)
    |> assign(:alpaca_period, "1M")
    |> assign(:kalshi_data, nil)
    |> assign(:kalshi_quick_trade_ticker, "")
    |> assign(:kalshi_quick_trade_units, "1")
    |> assign(:kalshi_quick_trade_side, "yes")
    |> assign(:kalshi_quick_trade_price, "1")
    |> assign(:kalshi_action_flash, nil)
    |> assign(:agent_log_entries, [])
    |> assign(:agent_log_subscribed_id, nil)
    |> assign(:alpaca_live_tick_enabled, false)
    |> assign(:alpaca_live_tick_status, :off)
    |> assign(:alpaca_live_tick_prices, %{})
    |> assign(:alpaca_live_tick_subscribed_symbols, [])
    |> assign(:wallet_txs, nil)
    |> assign(:wallet_tokens, nil)
    |> assign(:show_agent_context, false)
    |> assign(:agent_context_text, nil)
    |> assign(:agent_context_news, [])
    |> assign(:show_agent_token, false)
    |> assign(:show_option_a, false)
    |> assign(:show_option_b, false)
    |> assign(:show_option_c, false)
    |> assign(:portfolio_pnl_period, :all_time)
    |> assign(:attestation_count, 0)
    |> assign(:recent_attestations, [])
    |> assign(:all_attestations, [])
    |> assign(:polymarket_data, nil)
    |> assign(:polymarket_positions, [])
    |> assign(:polymarket_mode, :paper)
    |> assign(:forex_positions, [])
    |> assign(:forex_nav_history, [])
    |> assign(:forex_fetching, false)
    |> assign(:forex_instruments, [])
    |> assign(:forex_loading, false)
    |> assign(:forex_provider, :none)
    |> assign(:forex_oanda_env, nil)
    |> assign(:forex_account, nil)
    |> assign(:forex_candles, [])
    |> assign(:forex_symbol, "EUR_USD")
    |> assign(:forex_pricing, nil)
    |> assign(:forex_pricing_by_instrument, %{})
    |> assign(:forex_open_trades, [])
    |> assign(:forex_recent_trades, [])
    |> assign(:forex_quick_trade_units, "1000")
    |> assign(:forex_action_flash, nil)
    |> assign(:forex_pending_trade, nil)
    |> assign(:forex_chart_price, "M")
    |> assign(:stats_refresh_timer, nil)
    |> assign(:chat_messages, [])
    |> stream(:trades, [])
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Two query params we honor:
    #   - agent_id: which agent the dashboard is viewing
    #   - tab: which tab is active (preserves state across reloads;
    #     was previously socket-only so a reload always reset to overview)
    socket =
      case params["tab"] do
        nil -> socket
        raw -> apply_tab_change(socket, parse_tab(raw))
      end

    case params do
      %{"agent_id" => agent_id} ->
        # Stale/invalid agent_id in the URL used to raise Ecto.NoResultsError
        # via Trading.get_agent!/1 and crash-loop the LV. Fall back to the
        # overview route if the agent is gone.
        case safe_get_agent(agent_id) do
          nil ->
            {:noreply, push_patch(socket, to: ~p"/dashboard")}

          agent ->
            trades =
              try do
                Trading.list_trades(agent.id, limit: 20)
              rescue
                _ -> []
              end

            stats = safe_broker_stats(agent.organization_id, socket.assigns[:pnl_stats])

            if connected?(socket) do
              if socket.assigns.selected_agent do
                Phoenix.PubSub.unsubscribe(
                  KiteAgentHub.PubSub,
                  "agent:#{socket.assigns.selected_agent.id}"
                )
              end

              Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{agent.id}")
              fetch_chain_data(agent)
            end

            {:noreply,
             socket
             |> assign(:selected_agent, agent)
             |> assign(:pnl_stats, stats)
             |> assign(:attestation_count, attestation_count(agent))
             |> assign(:recent_attestations, recent_attestations(agent))
             |> assign(
               :all_attestations,
               if(socket.assigns.active_tab == :attestations,
                 do: all_attestations(agent),
                 else: []
               )
             )
             |> assign(:wallet_balance_eth, nil)
             |> assign(:block_number, nil)
             |> stream(:trades, trades, reset: true)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  defp parse_tab("overview"), do: :overview
  defp parse_tab("attestations"), do: :attestations
  defp parse_tab("wallet"), do: :wallet
  defp parse_tab("edge_scorer"), do: :edge_scorer
  defp parse_tab("alpaca"), do: :alpaca
  defp parse_tab("kalshi"), do: :kalshi
  defp parse_tab("polymarket"), do: :polymarket
  defp parse_tab("forex"), do: :forex
  defp parse_tab("logs"), do: :logs
  defp parse_tab("portfolio"), do: :portfolio
  defp parse_tab(_), do: :overview

  # Shared tab-switch side effects (firing the right loader, scheduling
  # tab refreshes). Pulled out so handle_params (URL-driven) and
  # switch_tab (button-click) both produce the same result.
  defp apply_tab_change(socket, tab_atom) do
    socket =
      case tab_atom do
        :edge_scorer ->
          send(self(), :load_edge_scores)
          assign(socket, :edge_scores_loading, true)

        :wallet ->
          send(self(), :load_wallet_txs)
          send(self(), :load_wallet_tokens)

          socket
          |> assign(:wallet_txs, :loading)
          |> assign(:wallet_tokens, :loading)

        :alpaca ->
          send(self(), :load_alpaca)
          schedule_tab_refresh(:alpaca)
          assign(socket, :alpaca_data, :loading)

        :kalshi ->
          send(self(), :load_kalshi)
          schedule_tab_refresh(:kalshi)
          assign(socket, :kalshi_data, :loading)

        :attestations ->
          assign(socket, :all_attestations, all_attestations(socket.assigns.selected_agent))

        :polymarket ->
          send(self(), :load_polymarket)
          assign(socket, :polymarket_data, :loading)

        :forex ->
          send(self(), :load_forex)
          schedule_tab_refresh(:forex)
          # Warmup chaining is handled inside the `:load_forex`
          # handler — after each successful fetch it enqueues the
          # next tick iff the buffer still needs samples AND the user
          # is still on this tab. The previous parallel +2/+4/+6s
          # burst was discarded by the `forex_fetching` guard whenever
          # the first OANDA fetch took >2s (common case), so the
          # buffer never crossed the 2-sample threshold and the
          # sparkline stayed in "Building chart…" (Mico 10112 +
          # CyberSec 10113).
          assign(socket, :forex_loading, true)

        :portfolio ->
          # Cross-broker breakdown reads from the existing alpaca_data,
          # kalshi_data, and forex_account assigns. Each broker's load
          # already runs inside its own `Repo.with_user` block (RLS
          # scope preserved). On Portfolio tab entry we eagerly fan-out
          # all three loads so the pie chart and stats reflect current
          # state regardless of which broker tabs the user has visited
          # this session. Loading state for each broker is set so the
          # render fallbacks display "Loading..." instead of "$0".
          send(self(), :load_alpaca)
          send(self(), :load_kalshi)
          send(self(), :load_forex)

          socket
          |> assign(:alpaca_data, :loading)
          |> assign(:kalshi_data, :loading)
          |> assign(:forex_loading, true)

        :logs ->
          # Load existing log entries from the ring buffer and subscribe
          # to real-time updates for the selected agent. Track the
          # subscribed id on the socket so a later tab switch can
          # unsubscribe (avoids a PubSub leak when the user navigates
          # to multiple agents during one LiveView session).
          selected = socket.assigns.selected_agent

          if selected do
            alias KiteAgentHub.Kite.AgentLog
            AgentLog.subscribe(selected.id)
            entries = AgentLog.recent(selected.id)

            socket
            |> assign(:agent_log_entries, entries)
            |> assign(:agent_log_subscribed_id, selected.id)
          else
            socket
          end

        _ ->
          # Switching AWAY from the logs tab — unsubscribe so we do
          # not keep receiving events into a tab that is not rendering.
          case socket.assigns[:agent_log_subscribed_id] do
            nil ->
              socket

            id ->
              KiteAgentHub.Kite.AgentLog.unsubscribe(id)
              assign(socket, :agent_log_subscribed_id, nil)
          end
      end

    # If the user is leaving the Alpaca tab while live ticks are on,
    # release the per-symbol PubSub subscriptions so we do not keep
    # receiving frames into a tab that is not rendering.
    socket =
      if tab_atom != :alpaca and socket.assigns[:alpaca_live_tick_enabled] do
        disable_alpaca_live_ticks(socket)
      else
        socket
      end

    socket
    |> assign(:show_agent_token, false)
    |> assign(:show_option_a, false)
    |> assign(:show_option_b, false)
    |> assign(:show_option_c, false)
    |> assign(:active_tab, tab_atom)
  end

  defp safe_get_agent(agent_id) do
    try do
      Trading.get_agent!(agent_id)
    rescue
      Ecto.NoResultsError -> nil
      _ -> nil
    end
  end

  # Polymarket.mode/0 reads Application env. Wrap anyway so a boot-order
  # race or config read failure cannot crash mount.
  defp safe_polymarket_mode do
    try do
      Polymarket.mode()
    rescue
      e ->
        require Logger
        Logger.error("DashboardLive: Polymarket.mode/0 crashed: #{inspect(e)}")
        :paper
    end
  end

  # ── Events ────────────────────────────────────────────────────────────────────

  # Always collapse any revealed secrets when the user navigates
  # away — prevents api_token / prompt text from sitting exposed
  # on a screen the operator is not actively looking at.
  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = parse_tab(tab)
    agent_id = socket.assigns[:selected_agent] && socket.assigns.selected_agent.id

    # push_patch updates the URL; handle_params then runs apply_tab_change.
    # Persisting tab in the URL means a browser reload keeps the user on
    # the tab they were on instead of bouncing back to overview.
    path =
      case agent_id do
        nil -> ~p"/dashboard?#{[tab: Atom.to_string(tab_atom)]}"
        id -> ~p"/dashboard?#{[agent_id: id, tab: Atom.to_string(tab_atom)]}"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("toggle_reveal", %{"target" => target}, socket) do
    key =
      case target do
        "agent_token" -> :show_agent_token
        "option_a" -> :show_option_a
        "option_b" -> :show_option_b
        "option_c" -> :show_option_c
        _ -> nil
      end

    socket =
      if key do
        assign(socket, key, !Map.get(socket.assigns, key, false))
      else
        socket
      end

    {:noreply, socket}
  end

  # Re-fetches live account data while the tab is visible. The tick
  # handler below checks `active_tab` and is a no-op if the user has
  # moved away, so stale intervals never run forever.
  #
  # Forex polls faster (10s) because FX prices move every tick. Other
  # tabs poll at 30s — broker portfolio state does not change as fast
  # and a tighter cadence would burn the DB pool needlessly.
  defp schedule_tab_refresh(:forex),
    # 30s cadence (was 10s) — same as Alpaca/Kalshi. The faster tick was
    # too aggressive once the tab grew anime.js CountUp hooks: every
    # refresh re-rendered the hero + KPI strip and the animations made
    # the tab feel like it was reloading constantly (Mico 10027).
    do: Process.send_after(self(), {:tab_refresh, :forex}, 30_000)

  defp schedule_tab_refresh(tab) do
    Process.send_after(self(), {:tab_refresh, tab}, 30_000)
  end

  # Debounce broker stats refresh so rapid-fire trade broadcasts
  # (e.g., create + settle in the same second) collapse into one API
  # call instead of hammering Alpaca/Kalshi on every event.
  defp schedule_stats_refresh(socket) do
    existing = socket.assigns[:stats_refresh_timer]
    if existing, do: Process.cancel_timer(existing)

    timer = Process.send_after(self(), :refresh_broker_stats, @stats_debounce_ms)
    assign(socket, :stats_refresh_timer, timer)
  end

  @impl true
  def handle_event("activate_vault", %{"vault" => %{"vault_address" => vault_address}}, socket) do
    agent = socket.assigns.selected_agent
    vault_address = String.trim(vault_address)

    cond do
      is_nil(agent) ->
        {:noreply, put_flash(socket, :error, "No agent selected.")}

      not String.match?(vault_address, ~r/^0x[0-9a-fA-F]{40}$/) ->
        {:noreply, put_flash(socket, :error, "Invalid vault address — must be a 0x EVM address.")}

      true ->
        try do
          case Trading.activate_agent(agent, vault_address) do
            {:ok, updated_agent} ->
              {:noreply,
               socket
               |> assign(:selected_agent, updated_agent)
               |> update(:agents, &replace_agent(&1, updated_agent))
               |> put_flash(:info, "Agent activated! Vault is live on Kite chain.")}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "Failed to activate agent.")}
          end
        rescue
          e ->
            Logger.warning("DashboardLive activate_vault crashed: #{inspect(e)}")
            {:noreply, put_flash(socket, :error, "Failed to activate agent.")}
        end
    end
  end

  def handle_event("pause_agent", _params, socket) do
    try do
      case Trading.pause_agent(socket.assigns.selected_agent) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:selected_agent, updated)
           |> update(:agents, &replace_agent(&1, updated))
           |> put_flash(:info, "Agent paused.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not pause agent.")}
      end
    rescue
      e ->
        Logger.warning("DashboardLive pause_agent crashed: #{inspect(e)}")
        {:noreply, put_flash(socket, :error, "Could not pause agent.")}
    end
  end

  def handle_event("resume_agent", _params, socket) do
    try do
      case Trading.resume_agent(socket.assigns.selected_agent) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:selected_agent, updated)
           |> update(:agents, &replace_agent(&1, updated))
           |> put_flash(:info, "Agent resumed.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not resume agent.")}
      end
    rescue
      e ->
        Logger.warning("DashboardLive resume_agent crashed: #{inspect(e)}")
        {:noreply, put_flash(socket, :error, "Could not resume agent.")}
    end
  end

  def handle_event("show_agent_context", _params, socket) do
    agent = socket.assigns.selected_agent

    if agent do
      try do
        context = KiteAgentHub.Trading.AgentContext.generate(agent)
        news = recent_news_for_agent(agent)

        {:noreply,
         socket
         |> assign(:show_agent_context, true)
         |> assign(:agent_context_text, context)
         |> assign(:agent_context_news, news)}
      rescue
        e ->
          Logger.warning("DashboardLive show_agent_context crashed: #{inspect(e)}")
          {:noreply, put_flash(socket, :error, "Could not load agent context.")}
      end
    else
      {:noreply, put_flash(socket, :error, "No agent selected.")}
    end
  end

  # Pull the symbols the agent is currently exposed to (open trades)
  # and ask NewsBuffer for recent sanitized headlines for any of
  # them. The buffer returns at most 10 items already sanitized
  # (HTML stripped, control chars stripped, byte-capped); this
  # function is just the fan-in.
  defp recent_news_for_agent(agent) do
    symbols =
      agent.id
      |> KiteAgentHub.Trading.list_open_trades()
      |> Enum.map(& &1.market)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    KiteAgentHub.News.Buffer.recent(symbols)
  rescue
    e ->
      require Logger
      Logger.warning("DashboardLive: news fetch failed: #{Exception.message(e)}")
      []
  end

  def handle_event("close_agent_context", _params, socket) do
    {:noreply, assign(socket, :show_agent_context, false)}
  end

  # Portfolio donut interactivity is now driven entirely client-side by
  # the DonutChart JS hook (assets/js/app.js) — no LV round-trip on
  # hover. The hook reads broker data from `data-*` attributes set in
  # HEEx and animates arcs + cards locally. This shrinks the LV event
  # surface (no `portfolio_hover` handler / `:portfolio_hovered_slice`
  # assign) and eliminates network latency on every hover frame.

  # P&L period toggle (Phorari 9951 spec / CyberSec 9952 whitelist). Only
  # `:all_time` returns real numbers today — other periods are surfaced
  # in the UI as "—" with a tooltip until BrokerStats day_change is
  # piped into the breakdown.
  @portfolio_pnl_periods ~w[today week month all_time]a

  def handle_event("set_pnl_period", %{"period" => period}, socket) do
    case String.to_existing_atom(period) do
      atom when atom in @portfolio_pnl_periods ->
        {:noreply, assign(socket, :portfolio_pnl_period, atom)}

      _ ->
        {:noreply, socket}
    end
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("set_pnl_period", _params, socket), do: {:noreply, socket}

  def handle_event("alpaca_period", %{"period" => period}, socket)
      when period in ~w(1D 3D 1W 1M 3M 6M 1Y 2Y 3Y All) do
    send(self(), {:load_alpaca, period})

    {:noreply,
     socket
     |> assign(:alpaca_period, period)
     |> assign(:alpaca_data, :loading)}
  end

  # Live tick toggle: switch between 30s polling and push-based streaming
  # for the Alpaca tab's open-positions price column. When ON, we start
  # the AlpacaStream :stocks feed for the symbols currently in view and
  # subscribe this LiveView to each per-symbol PubSub topic. Trade-tick
  # events flow into @alpaca_live_tick_prices and overlay the static
  # `current_price` from the polling response.
  def handle_event("alpaca_live_tick_toggle", _params, socket) do
    if socket.assigns.alpaca_live_tick_enabled do
      {:noreply, disable_alpaca_live_ticks(socket)}
    else
      {:noreply, enable_alpaca_live_ticks(socket)}
    end
  end

  # ── PubSub / async messages ───────────────────────────────────────────────────

  @impl true
  def handle_info({:trade_created, trade}, socket) do
    try do
      {:noreply,
       socket
       |> schedule_stats_refresh()
       |> stream_insert(:trades, trade, at: 0)}
    rescue
      e ->
        require Logger

        Logger.warning(
          "DashboardLive: :trade_created handler raised — #{Exception.message(e)} — ignoring to keep socket alive"
        )

        {:noreply, socket}
    end
  end

  def handle_info({:trade_updated, trade}, socket) do
    try do
      agent = socket.assigns[:selected_agent]
      active_tab = socket.assigns[:active_tab]

      {att_count, recent_att, all_att} =
        try do
          {
            attestation_count(agent),
            recent_attestations(agent),
            if(active_tab == :attestations,
              do: all_attestations(agent),
              else: socket.assigns[:all_attestations] || []
            )
          }
        rescue
          _ ->
            {
              socket.assigns[:attestation_count] || 0,
              socket.assigns[:recent_attestations] || [],
              socket.assigns[:all_attestations] || []
            }
        end

      # Re-fetch the visible trades from the DB instead of stream_inserting
      # the lone updated row. If the prior :trade_created broadcast was
      # missed (e.g. socket disconnected during the longpoll-bounce loop),
      # a bare stream_insert here would land the row at the END of the
      # stream — invisible to anyone looking at the top. A reset keeps the
      # stream canonically ordered by inserted_at desc and self-heals
      # whenever any trade event lands.
      trades = safe_list_trades(trade.kite_agent_id)

      {:noreply,
       socket
       |> schedule_stats_refresh()
       |> assign(:attestation_count, att_count)
       |> assign(:recent_attestations, recent_att)
       |> assign(:all_attestations, all_att)
       |> stream(:trades, trades, reset: true)}
    rescue
      e ->
        require Logger

        Logger.warning(
          "DashboardLive: :trade_updated handler raised — #{Exception.message(e)} — ignoring to keep socket alive"
        )

        {:noreply, socket}
    end
  end

  defp safe_list_trades(agent_id) do
    Trading.list_trades(agent_id, limit: 20)
  rescue
    _ -> []
  end

  # Debounced stats refresh: only fires once after the debounce window,
  # regardless of how many trade broadcasts arrived in that window.
  def handle_info(:refresh_broker_stats, socket) do
    stats =
      case socket.assigns[:organization] do
        %{id: org_id} -> safe_broker_stats(org_id, socket.assigns[:pnl_stats])
        _ -> socket.assigns[:pnl_stats]
      end

    {:noreply,
     socket
     |> assign(:pnl_stats, stats)
     |> assign(:stats_refresh_timer, nil)}
  end

  def handle_info({:agent_updated, agent}, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent, agent)
     |> update(:agents, &replace_agent(&1, agent))}
  end

  # Async wallet balance from Task
  def handle_info({ref, {:wallet_balance, balance_wei}}, socket) do
    Process.demonitor(ref, [:flush])
    eth = wei_to_eth(balance_wei)
    {:noreply, assign(socket, :wallet_balance_eth, eth)}
  end

  # Async block number from Task
  def handle_info({ref, {:block_number, number}}, socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, :block_number, number)}
  end

  # Ignore Task :DOWN — chain data is non-critical
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  # Async broker stats loading — PR #98. Mount returns instantly with
  # empty_broker_stats/0; this fires after connect and pulls real numbers
  # from Alpaca + Kalshi via safe_broker_stats/2. Same pattern as
  # :load_edge_scores below.
  def handle_info(:load_broker_stats, socket) do
    stats =
      case socket.assigns[:organization] do
        %{id: org_id} -> safe_broker_stats(org_id, socket.assigns[:pnl_stats])
        _ -> socket.assigns[:pnl_stats] || empty_broker_stats()
      end

    {:noreply, assign(socket, :pnl_stats, stats)}
  end

  # Async edge scorer loading. Wrapped in try/rescue so a scorer raise
  # (e.g. nil field from a partially-loaded broker position) never kills
  # the LiveView, which used to propagate as a page-reload storm for
  # every dashboard visitor.
  def handle_info(:load_edge_scores, socket) do
    require Logger

    scores =
      try do
        EdgeScorer.score_all()
      rescue
        e ->
          Logger.warning("DashboardLive: EdgeScorer crashed: #{inspect(e)}")
          socket.assigns[:edge_scores] || []
      end

    portfolio =
      if socket.assigns.organization do
        try do
          PortfolioEdgeScorer.score_portfolio(socket.assigns.organization.id)
        rescue
          e ->
            Logger.warning("DashboardLive: PortfolioEdgeScorer crashed: #{inspect(e)}")
            socket.assigns[:portfolio_scores]
        end
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:edge_scores, scores)
     |> assign(:portfolio_scores, portfolio)
     |> assign(:edge_scores_loading, false)}
  end

  # Async wallet transaction history via Blockscout
  def handle_info(:load_wallet_txs, socket) do
    agent = socket.assigns.selected_agent

    txs =
      if agent && agent.wallet_address do
        try do
          case KiteAgentHub.Kite.Blockscout.transactions(
                 agent.wallet_address,
                 10,
                 agent.chain_id || KiteAgentHub.Kite.ChainId.default()
               ) do
            {:ok, txs} -> txs
            _ -> []
          end
        rescue
          _ -> []
        end
      else
        []
      end

    {:noreply, assign(socket, :wallet_txs, txs)}
  end

  # Async ERC-20 token balances via Blockscout. Native KITE balance is fetched
  # separately via RPC.get_balance/1; this populates the additional tokens the
  # wallet holds (USDT and any others) so they show up in the wallet tab.
  def handle_info(:load_wallet_tokens, socket) do
    agent = socket.assigns.selected_agent

    tokens =
      if agent && agent.wallet_address do
        try do
          case KiteAgentHub.Kite.Blockscout.token_balances(agent.wallet_address) do
            {:ok, list} -> list
            _ -> []
          end
        rescue
          _ -> []
        end
      else
        []
      end

    {:noreply, assign(socket, :wallet_tokens, tokens)}
  end

  # Async Alpaca data loading. Wrapped so a client timeout / malformed
  # response cannot crash the LV.
  def handle_info(:load_alpaca, socket) do
    socket =
      try do
        load_alpaca_data(socket)
      rescue
        _ -> assign(socket, :alpaca_data, :error)
      end

    {:noreply, socket}
  end

  def handle_info({:load_alpaca, period}, socket) do
    socket =
      try do
        load_alpaca_data(socket, period)
      rescue
        _ -> assign(socket, :alpaca_data, :error)
      end

    {:noreply, socket}
  end

  # Periodic refresh for Alpaca/Kalshi tabs — keeps live portfolio
  # + equity within ~30s of the actual broker dashboard. No-op if
  # the user has switched away from that tab.
  def handle_info({:tab_refresh, :alpaca}, %{assigns: %{active_tab: :alpaca}} = socket) do
    send(self(), :load_alpaca)
    schedule_tab_refresh(:alpaca)
    {:noreply, socket}
  end

  def handle_info({:tab_refresh, :kalshi}, %{assigns: %{active_tab: :kalshi}} = socket) do
    send(self(), :load_kalshi)
    schedule_tab_refresh(:kalshi)
    {:noreply, socket}
  end

  def handle_info({:tab_refresh, :forex}, %{assigns: %{active_tab: :forex}} = socket) do
    send(self(), :load_forex)
    schedule_tab_refresh(:forex)
    {:noreply, socket}
  end

  def handle_info({:tab_refresh, _other}, socket), do: {:noreply, socket}

  # Async Polymarket tab loader. Fetches live Gamma markets (no auth)
  # and any paper positions for the current org + selected agent.
  # Fully try/rescue wrapped per feedback_kah_lv_rescue — any transient
  # Gamma or Repo failure leaves the tab in an empty-but-usable state.
  def handle_info(:load_polymarket, socket) do
    require Logger

    markets =
      try do
        Polymarket.list_markets(limit: 20)
      rescue
        e ->
          Logger.error("DashboardLive :load_polymarket markets crashed: #{inspect(e)}")
          []
      end

    positions =
      case socket.assigns[:organization] do
        %{id: org_id} ->
          try do
            agent = socket.assigns[:selected_agent]

            if agent do
              Polymarket.list_agent_positions(org_id, agent.id)
            else
              Polymarket.list_positions(org_id)
            end
          rescue
            e ->
              Logger.error("DashboardLive :load_polymarket positions crashed: #{inspect(e)}")
              []
          end

        _ ->
          []
      end

    {:noreply,
     socket
     |> assign(:polymarket_data, markets)
     |> assign(:polymarket_positions, positions)}
  end

  # Async ForEx tab loader. Prefers OANDA live when configured, then
  # OANDA practice. One pass pulls everything the tab renders:
  # account summary, candles for the selected symbol, ALL instruments
  # plus their live bid/ask (so the instruments rail is clickable
  # tickers, not a dead chip dump), open positions and trades, and the
  # selected agents recent OANDA TradeRecord rows. Every fetch is
  # try/rescue wrapped so a transient OANDA outage cannot crash the LV
  # (feedback_kah_lv_rescue).
  #
  # Concurrency guard (CyberSec 10057): the warmup burst from `:forex`
  # tab activation enqueues 3 extra `:load_forex` messages at 2s
  # intervals. If the user toggles tabs faster than OANDA responds,
  # those bursts could stack overlapping HTTP requests against the
  # broker. `:forex_fetching` is flipped on at the start of every
  # handler invocation and back off when the assigns are committed;
  # any tick that arrives mid-fetch no-ops.
  def handle_info(:load_forex, %{assigns: %{forex_fetching: true}} = socket) do
    {:noreply, socket}
  end

  def handle_info(:load_forex, socket) do
    require Logger
    socket = assign(socket, :forex_fetching, true)

    symbol = socket.assigns[:forex_symbol] || "EUR_USD"
    agent = socket.assigns[:selected_agent]
    chart_price = socket.assigns[:forex_chart_price] || "M"

    {positions, instruments, provider, oanda_env, account, candles, pricing_by_instrument,
     open_trades, recent_trades} =
      case socket.assigns[:organization] do
        %{id: org_id} ->
          try do
            case Oanda.active_env(org_id) do
              env when env in [:live, :practice] ->
                instruments = Oanda.list_instruments(org_id, env)

                pricing_by_instrument =
                  instruments
                  |> instrument_names()
                  |> case do
                    [] -> %{}
                    names -> price_map(Oanda.pricing(org_id, names, env))
                  end

                {Oanda.list_positions(org_id, env), instruments, :oanda, env,
                 Oanda.account_summary(org_id, env),
                 Oanda.candles(org_id, symbol, "M5", 120, env, chart_price),
                 pricing_by_instrument, Oanda.list_open_trades(org_id, env),
                 recent_oanda_trades(agent)}

              _ ->
                {[], [], :none, nil, nil, [], %{}, [], []}
            end
          rescue
            e ->
              Logger.error("DashboardLive :load_forex crashed: #{inspect(e)}")
              {[], [], :none, nil, nil, [], %{}, [], []}
          end

        _ ->
          {[], [], :none, nil, nil, [], %{}, [], []}
      end

    pricing = Map.get(pricing_by_instrument, symbol)

    nav_history = append_forex_nav_sample(socket.assigns[:forex_nav_history] || [], account)

    # Warmup chain (Mico 10112 + CyberSec 10113): the parallel +2/+4/+6s
    # burst from earlier was eaten by the `forex_fetching` guard
    # whenever the first OANDA fetch took >2s. Instead, each successful
    # fetch now queues the next one 2s later — but only while the user
    # is still on the Forex tab AND the buffer is still short of the
    # 4-sample warmup target. Once we have 4 samples the chain stops
    # and the regular 30s `:tab_refresh` cadence takes over. Each
    # fetch starts after the previous one finishes, so the guard
    # never drops a warmup tick.
    if socket.assigns[:active_tab] == :forex and length(nav_history) < 4 do
      Process.send_after(self(), :load_forex, 2_000)
    end

    {:noreply,
     socket
     |> assign(:forex_positions, positions)
     |> assign(:forex_instruments, instruments)
     |> assign(:forex_provider, provider)
     |> assign(:forex_oanda_env, oanda_env)
     |> assign(:forex_account, account)
     |> assign(:forex_nav_history, nav_history)
     |> assign(:forex_candles, candles)
     |> assign(:forex_pricing, pricing)
     |> assign(:forex_pricing_by_instrument, pricing_by_instrument)
     |> assign(:forex_open_trades, open_trades)
     |> assign(:forex_recent_trades, recent_trades)
     |> assign(:forex_loading, false)
     |> assign(:forex_fetching, false)}
  end

  # Session-scoped NAV ring buffer for the Forex tab sparkline. Each
  # call appends `{unix_ts, nav_float}` if the account snapshot has a
  # readable NAV, then trims to the most recent 288 samples (24h of
  # 5-min refreshes — CyberSec 10010 cap to bound memory). Snapshots
  # without a NAV (account nil / OANDA unavailable) leave the buffer
  # untouched so reconnects don't introduce a gap row.
  @forex_nav_history_max 288

  defp append_forex_nav_sample(history, account) when is_list(history) do
    case forex_nav_value(account) do
      nil ->
        history

      nav when is_float(nav) ->
        ts = System.system_time(:second)
        [{ts, nav} | history] |> Enum.take(@forex_nav_history_max)
    end
  end

  defp append_forex_nav_sample(_history, _account), do: []

  defp forex_nav_value(%{} = account) do
    raw =
      Map.get(account, "NAV") || Map.get(account, :NAV) ||
        Map.get(account, "nav") || Map.get(account, :nav)

    cond do
      is_number(raw) -> raw * 1.0
      is_binary(raw) -> parse_float(raw)
      true -> nil
    end
  end

  defp forex_nav_value(_), do: nil

  # Read a numeric field off the OANDA `account_summary` payload and
  # coerce it to a float. OANDA returns most balances as JSON strings
  # ("12345.67"). Used by the Forex hero + KPI strip so anime.js
  # `CountUp` (which expects `Number()`-coercible attrs) can animate.
  # Falls back to 0.0 on nil / malformed input so the UI never crashes.
  defp forex_field_float(%{} = account, key) when is_binary(key) do
    # Look up by the string key only — OANDA returns string-keyed
    # JSON. We deliberately avoid `String.to_atom/1` here so a
    # malformed payload can never create a new atom. Callers pass
    # compile-time string constants ("NAV", "balance", etc.).
    case Map.get(account, key) do
      v when is_number(v) -> v * 1.0
      v when is_binary(v) -> parse_float(v)
      _ -> 0.0
    end
  end

  defp forex_field_float(_, _), do: 0.0

  # Render a unix timestamp as a session-relative HH:MM clock string for
  # the Session NAV sparkline x-axis labels. We display in UTC to avoid
  # pulling tz state into the LV; the sparkline only spans a session so
  # users care about relative ordering, not wall-clock localisation.
  defp format_session_time(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      _ -> "—"
    end
  end

  defp format_session_time(_), do: "—"

  # Pull names off OANDAs instruments list, capped at the pricing
  # endpoints 100-instrument limit. Empty list when malformed.
  defp instrument_names(instruments) when is_list(instruments) do
    instruments
    |> Enum.map(fn i -> Map.get(i, "name") end)
    |> Enum.filter(&is_binary/1)
    |> Enum.take(100)
  end

  defp instrument_names(_), do: []

  # Index pricing rows by instrument so the template can do O(1)
  # lookups for the rail and the active-symbol quote pill.
  defp price_map(pricing) when is_list(pricing) do
    Map.new(pricing, fn p ->
      {Map.get(p, "instrument"), p}
    end)
    |> Map.delete(nil)
  end

  defp price_map(_), do: %{}

  defp recent_oanda_trades(%{id: agent_id}) when is_binary(agent_id) do
    KiteAgentHub.Trading.list_trades(agent_id, platform: "oanda", limit: 12)
  rescue
    _ -> []
  end

  defp recent_oanda_trades(_), do: []

  # Symbol change: re-queue a load with the new symbol so the chart
  # refreshes against the correct instrument's candles.
  def handle_event("forex_symbol", %{"symbol" => symbol}, socket) do
    safe =
      if is_binary(symbol) and Regex.match?(~r/^[A-Z]{2,8}_[A-Z]{2,8}$/, symbol),
        do: symbol,
        else: "EUR_USD"

    send(self(), :load_forex)

    {:noreply,
     socket
     |> assign(:forex_symbol, safe)
     |> assign(:forex_loading, true)
     |> assign(:forex_action_flash, nil)}
  end

  # Chart price-source toggle: M (mid) / B (bid) / A (ask). Mid is
  # the default and most-common chart source. Bid/Ask let traders
  # see exactly where their fills would land. Re-fetches the candle
  # series from OANDA against the chosen price.
  def handle_event("forex_chart_price", %{"price" => price}, socket)
      when price in ["M", "B", "A"] do
    send(self(), :load_forex)

    {:noreply,
     socket
     |> assign(:forex_chart_price, price)
     |> assign(:forex_loading, true)}
  end

  def handle_event("forex_chart_price", _params, socket), do: {:noreply, socket}

  # Stage a Quick Trade for review — opens the confirmation modal
  # with the parsed side/units/symbol. The actual order does NOT
  # submit until the user clicks Confirm. The QuickTradeForm JS hook
  # routes around this handler entirely when the user has previously
  # checked "do not ask me again", so review-clicks only happen for
  # users who want the safety net.
  def handle_event("forex_quick_trade_review", params, socket) do
    agent = socket.assigns[:selected_agent]
    org_id = get_in(socket.assigns, [:organization, Access.key(:id)])
    symbol = socket.assigns[:forex_symbol] || "EUR_USD"
    side = params["side"] || "buy"
    raw_units = parse_positive_int(params["units"] || socket.assigns[:forex_quick_trade_units])

    cond do
      is_nil(agent) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "Select an agent first."})}

      agent.agent_type != "trading" ->
        {:noreply,
         assign(
           socket,
           :forex_action_flash,
           {:error, "Selected agent is not a trading agent."}
         )}

      is_nil(org_id) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "No workspace."})}

      raw_units in [nil, 0] ->
        {:noreply,
         assign(socket, :forex_action_flash, {:error, "Units must be a positive integer."})}

      true ->
        {:noreply,
         assign(socket, :forex_pending_trade, %{
           side: side,
           symbol: symbol,
           units: raw_units
         })}
    end
  end

  # Confirm fires the actual trade by reusing the existing
  # forex_quick_trade flow, then clears the modal. The pending
  # struct carried side/symbol/units, so we synthesize the params the
  # main handler expects.
  def handle_event("forex_quick_trade_confirm", _params, socket) do
    case socket.assigns[:forex_pending_trade] do
      %{side: side, units: units} ->
        socket = assign(socket, :forex_pending_trade, nil)

        handle_event(
          "forex_quick_trade",
          %{"side" => side, "units" => Integer.to_string(units)},
          socket
        )

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("forex_quick_trade_cancel", _params, socket) do
    {:noreply, assign(socket, :forex_pending_trade, nil)}
  end

  # Quick Trade — enqueues a PaperExecutionWorker job for the selected
  # agent so the order goes through the same pipeline as agent-API
  # submissions: TradeRecord row created up-front, OANDA call routed
  # via the worker, fill+settlement handled by the worker, attestation
  # enqueued (when the agent has it on). Every dashboard trade lands
  # in the trades stream and on /trades exactly like agent trades —
  # NO TRADE GOES UNTRACKED.
  #
  # The QuickTradeForm JS hook can route to this handler directly
  # (skipping the modal) when the user has set the "do not ask me
  # again" preference in localStorage.
  def handle_event("forex_quick_trade", params, socket) do
    agent = socket.assigns[:selected_agent]
    org_id = get_in(socket.assigns, [:organization, Access.key(:id)])
    symbol = socket.assigns[:forex_symbol] || "EUR_USD"
    side = params["side"] || "buy"
    raw_units = parse_positive_int(params["units"] || socket.assigns[:forex_quick_trade_units])

    cond do
      is_nil(agent) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "Select an agent first."})}

      agent.agent_type != "trading" ->
        {:noreply,
         assign(
           socket,
           :forex_action_flash,
           {:error, "Selected agent is not a trading agent."}
         )}

      is_nil(org_id) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "No workspace."})}

      raw_units in [nil, 0] ->
        {:noreply,
         assign(socket, :forex_action_flash, {:error, "Units must be a positive integer."})}

      true ->
        args = %{
          "agent_id" => agent.id,
          "organization_id" => org_id,
          "provider" => "oanda_practice",
          "symbol" => symbol,
          "side" => side,
          "units" => raw_units,
          "mode" => "paper",
          "client_order_id" => "kah-quicktrade-#{Ecto.UUID.generate()}"
        }

        enqueue_paper_trade(args, socket, "#{String.upcase(side)} #{raw_units} #{symbol}",
          on_success_units: raw_units
        )
    end
  end

  # Close a position by submitting a counter-direction reduce_only
  # trade through the same worker — keeps the close on the trades
  # stream and on /trades. Sizing is pulled from the cached forex
  # positions list. Falls back to OANDAs /positions/{}/close endpoint
  # only when we have no cached row to size from (rare; happens if
  # the tab has not loaded yet) — in that case we surface that no
  # KAH trade row was created.
  def handle_event("forex_close_position", %{"instrument" => instrument}, socket) do
    require Logger

    agent = socket.assigns[:selected_agent]
    org_id = get_in(socket.assigns, [:organization, Access.key(:id)])

    cond do
      is_nil(agent) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "Select an agent first."})}

      agent.agent_type != "trading" ->
        {:noreply,
         assign(
           socket,
           :forex_action_flash,
           {:error, "Selected agent is not a trading agent."}
         )}

      is_nil(org_id) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "No workspace."})}

      not is_binary(instrument) or
          not Regex.match?(~r/^[A-Z]{2,8}_[A-Z]{2,8}$/, instrument) ->
        {:noreply, assign(socket, :forex_action_flash, {:error, "Invalid instrument."})}

      true ->
        case position_for_close(socket.assigns[:forex_positions], instrument) do
          {:ok, side, units} ->
            args = %{
              "agent_id" => agent.id,
              "organization_id" => org_id,
              "provider" => "oanda_practice",
              "symbol" => instrument,
              "side" => side,
              "units" => units,
              "mode" => "paper",
              "position_fill" => "reduce_only",
              "client_order_id" => "kah-quickclose-#{Ecto.UUID.generate()}"
            }

            enqueue_paper_trade(
              args,
              socket,
              "Close #{instrument} (#{units}u counter-#{side})"
            )

          {:error, :not_found} ->
            case Oanda.close_practice_position(agent, org_id, instrument) do
              {:ok, _body} ->
                send(self(), :load_forex)

                {:noreply,
                 assign(
                   socket,
                   :forex_action_flash,
                   {:ok, "Closed #{instrument} (no KAH trade row — refresh the tab next time)"}
                 )}

              {:error, reason} ->
                Logger.warning("forex_close_position fallback error: #{inspect(reason)}")

                {:noreply,
                 assign(
                   socket,
                   :forex_action_flash,
                   {:error, "OANDA rejected close: #{format_oanda_error(reason)}"}
                 )}
            end
        end
    end
  end

  def handle_event("forex_quick_trade_units", %{"units" => units}, socket) do
    {:noreply, assign(socket, :forex_quick_trade_units, units)}
  end

  # Kalshi quick-trade. Mirrors `forex_quick_trade` but routes through
  # `provider: "kalshi"` and uses the Kalshi-specific assigns + flash.
  # Trading-agents only — same fail-closed gate that the agent-API
  # `POST /api/v1/trades` controller enforces server-side.
  def handle_event("kalshi_quick_trade", params, socket) do
    agent = socket.assigns[:selected_agent]
    org_id = get_in(socket.assigns, [:organization, Access.key(:id)])

    ticker =
      (params["ticker"] || socket.assigns[:kalshi_quick_trade_ticker] || "")
      |> String.trim()
      |> String.upcase()

    side = params["side"] || socket.assigns[:kalshi_quick_trade_side] || "yes"
    raw_units = parse_positive_int(params["units"] || socket.assigns[:kalshi_quick_trade_units])
    raw_price = parse_kalshi_price(params["price"] || socket.assigns[:kalshi_quick_trade_price])

    cond do
      is_nil(agent) ->
        {:noreply, assign(socket, :kalshi_action_flash, {:error, "Select an agent first."})}

      agent.agent_type != "trading" ->
        {:noreply,
         assign(
           socket,
           :kalshi_action_flash,
           {:error, "Selected agent is not a trading agent."}
         )}

      is_nil(org_id) ->
        {:noreply, assign(socket, :kalshi_action_flash, {:error, "No workspace."})}

      not KiteAgentHub.TradingPlatforms.KalshiClient.valid_ticker?(ticker) ->
        {:noreply,
         assign(
           socket,
           :kalshi_action_flash,
           {:error,
            "Ticker required (uppercase alphanumeric + dashes, e.g. KXETHD-25NOV30-B3500)."}
         )}

      side not in ["yes", "no"] ->
        {:noreply, assign(socket, :kalshi_action_flash, {:error, "Side must be 'yes' or 'no'."})}

      raw_units in [nil, 0] ->
        {:noreply,
         assign(socket, :kalshi_action_flash, {:error, "Count must be a positive integer."})}

      is_nil(raw_price) ->
        {:noreply,
         assign(
           socket,
           :kalshi_action_flash,
           {:error, "Limit price must be an integer 1..99 cents."}
         )}

      true ->
        args = %{
          "agent_id" => agent.id,
          "organization_id" => org_id,
          "provider" => "kalshi",
          "symbol" => ticker,
          "side" => side,
          "units" => raw_units,
          "price" => raw_price,
          "client_order_id" => "kah-kalshi-quicktrade-#{Ecto.UUID.generate()}"
        }

        enqueue_kalshi_trade(
          args,
          socket,
          "#{String.upcase(side)} #{raw_units} #{ticker} @ #{raw_price}c"
        )
    end
  end

  def handle_event("kalshi_quick_trade_ticker", %{"ticker" => ticker}, socket) do
    {:noreply, assign(socket, :kalshi_quick_trade_ticker, ticker)}
  end

  def handle_event("kalshi_quick_trade_units", %{"units" => units}, socket) do
    {:noreply, assign(socket, :kalshi_quick_trade_units, units)}
  end

  def handle_event("kalshi_quick_trade_side", %{"side" => side}, socket)
      when side in ["yes", "no"] do
    {:noreply, assign(socket, :kalshi_quick_trade_side, side)}
  end

  def handle_event("kalshi_quick_trade_price", %{"price" => price}, socket) do
    {:noreply, assign(socket, :kalshi_quick_trade_price, price)}
  end

  # Kalshi limit prices are integer cents 1..99. Returns nil for
  # anything outside that range so the caller fails closed and
  # `KalshiClient.place_order` never receives a bogus price.
  defp parse_kalshi_price(price) when is_integer(price) and price >= 1 and price <= 99, do: price

  defp parse_kalshi_price(price) when is_binary(price) do
    case Integer.parse(String.trim(price)) do
      {n, ""} when n >= 1 and n <= 99 -> n
      _ -> nil
    end
  end

  defp parse_kalshi_price(_), do: nil

  # ── Paper trade enqueue + close-side resolution ────────────────────

  # Insert the Oban job and emit a success/error flash. Pulled out so
  # both Quick Trade and Close share the same enqueue + UX path.
  defp enqueue_paper_trade(args, socket, action_label, opts \\ []) do
    require Logger

    case args |> KiteAgentHub.Workers.PaperExecutionWorker.new() |> Oban.insert() do
      {:ok, job} ->
        # Reload the tab so any open position changes show. The trades
        # stream picks up the new TradeRecord via the existing
        # :trade_created PubSub broadcast — no manual stream_insert
        # needed.
        send(self(), :load_forex)

        socket =
          socket
          |> assign(
            :forex_action_flash,
            {:ok, "#{action_label} queued (job ##{job.id}). Watch the Trades tab for fill."}
          )

        socket =
          case Keyword.get(opts, :on_success_units) do
            n when is_integer(n) -> assign(socket, :forex_quick_trade_units, Integer.to_string(n))
            _ -> socket
          end

        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("enqueue_paper_trade Oban insert failed: #{inspect(reason)}")

        {:noreply,
         assign(
           socket,
           :forex_action_flash,
           {:error, "Failed to enqueue trade: #{inspect(reason)}"}
         )}
    end
  end

  # Kalshi-specific enqueue. Same Oban worker as forex (PaperExecutionWorker)
  # but emits its outcome on `:kalshi_action_flash` and refreshes the
  # Kalshi tab on success. Kept separate from `enqueue_paper_trade/4`
  # because the forex helper hard-couples to forex assigns + the
  # `:load_forex` refresh path.
  defp enqueue_kalshi_trade(args, socket, action_label) do
    require Logger

    case args |> KiteAgentHub.Workers.PaperExecutionWorker.new() |> Oban.insert() do
      {:ok, job} ->
        send(self(), {:tab_refresh, :kalshi})

        {:noreply,
         assign(
           socket,
           :kalshi_action_flash,
           {:ok, "#{action_label} queued (job ##{job.id}). Watch the Trades tab for fill."}
         )}

      {:error, reason} ->
        Logger.warning("enqueue_kalshi_trade Oban insert failed: #{inspect(reason)}")

        {:noreply,
         assign(
           socket,
           :kalshi_action_flash,
           {:error, "Failed to enqueue Kalshi trade: #{inspect(reason)}"}
         )}
    end
  end

  # Pull side+units for a counter-trade close from the cached forex
  # positions list. Returns {:ok, "sell"|"buy", units} for the side
  # that flattens net exposure, or {:error, :not_found} if we have no
  # row to size from.
  defp position_for_close(positions, instrument) when is_list(positions) do
    Enum.find_value(positions, {:error, :not_found}, fn pos ->
      if Oanda.field(pos, "instrument", nil) == instrument do
        long = position_units_for(pos, "long")
        short = position_units_for(pos, "short")

        cond do
          long > 0 -> {:ok, "sell", long}
          short > 0 -> {:ok, "buy", short}
          true -> nil
        end
      end
    end)
  end

  defp position_for_close(_positions, _instrument), do: {:error, :not_found}

  # OANDA encodes side units as positive (long) or negative (short)
  # strings on each side map. We always return a positive integer
  # since side is already known from which key we pulled from.
  defp position_units_for(%{"long" => %{"units" => u}}, "long") when is_binary(u),
    do: parse_int_from_string(u) |> abs()

  defp position_units_for(%{"short" => %{"units" => u}}, "short") when is_binary(u),
    do: parse_int_from_string(u) |> abs()

  defp position_units_for(_, _), do: 0

  defp parse_int_from_string(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int_from_string(_), do: 0

  defp parse_positive_int(nil), do: nil
  defp parse_positive_int(""), do: nil

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: value
  defp parse_positive_int(_), do: nil

  # JSON snippet rendered into the Agent Context modal's Claude Code
  # setup details. Lives in a helper because raw `{` inside HEEx is
  # reserved as the start of an Elixir expression — wrapping the
  # literal in a function call sidesteps the parser.
  defp claude_settings_snippet do
    ~S"""
    {"permissions": {"allow": [
      "WebFetch(domain:kite-agent-hub.fly.dev)",
      "Bash(curl:*kite-agent-hub.fly.dev*)"
    ]}}
    """
  end

  # ── Alpaca live-tick toggle helpers ──────────────────────────────────────────

  alias KiteAgentHub.TradingPlatforms.{AlpacaStream, AlpacaStreamSupervisor}

  defp enable_alpaca_live_ticks(socket) do
    org_id = get_in(socket.assigns, [:organization, Access.key(:id)])

    symbols =
      case socket.assigns[:alpaca_data] do
        %{positions: positions} when is_list(positions) ->
          positions
          |> Enum.map(& &1.symbol)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        _ ->
          []
      end

    {stock_symbols, crypto_symbols, option_symbols} = partition_by_feed(symbols)

    cond do
      is_nil(org_id) ->
        assign(socket, :alpaca_live_tick_status, :error)

      symbols == [] ->
        # Toggle on with zero open positions = nothing to stream. Set
        # status so the UI can show the no-symbols hint instead of a
        # silent no-op.
        socket
        |> assign(:alpaca_live_tick_enabled, true)
        |> assign(:alpaca_live_tick_status, :no_symbols)

      true ->
        # Start the stocks + crypto + options feeds in parallel — each
        # is idempotent at the supervisor level (returns :already_started
        # if another LV or agent already opened it). Skip a feed entirely
        # when the corresponding symbol list is empty.
        if stock_symbols != [] do
          start_feed_safe(:stocks, org_id, stock_symbols)
          Enum.each(stock_symbols, &AlpacaStream.subscribe(:stocks, &1))
        end

        if crypto_symbols != [] do
          start_feed_safe(:crypto, org_id, crypto_symbols)
          Enum.each(crypto_symbols, &AlpacaStream.subscribe(:crypto, &1))
        end

        if option_symbols != [] do
          start_feed_safe(:options, org_id, option_symbols)
          Enum.each(option_symbols, &AlpacaStream.subscribe(:options, &1))
        end

        # Track every (feed, symbol) pair we subscribed to so disable
        # can release exactly those.
        subscribed =
          Enum.map(stock_symbols, &{:stocks, &1}) ++
            Enum.map(crypto_symbols, &{:crypto, &1}) ++
            Enum.map(option_symbols, &{:options, &1})

        socket
        |> assign(:alpaca_live_tick_enabled, true)
        |> assign(:alpaca_live_tick_status, :connecting)
        |> assign(:alpaca_live_tick_subscribed_symbols, subscribed)
    end
  end

  defp start_feed_safe(feed, org_id, symbols) do
    case AlpacaStreamSupervisor.start_feed(feed, org_id, symbols: symbols, topics: ["trades"]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.warning("alpaca_live_tick start_feed(#{feed}) failed: #{inspect(reason)}")
    end
  end

  # Bucket Alpaca symbols by stream feed. Three categories:
  #   * options — OCC contract format (`AAPL260117C00100000`), routes to
  #     the v1beta1/indicative stream
  #   * crypto  — slash form (`BTC/USD`) or legacy 6+ char ending in USD/USDC,
  #     routes to v1beta3 crypto
  #   * stocks  — everything else, routes to v2/iex
  # Returns `{stock_symbols, crypto_symbols, option_symbols}`.
  @doc false
  def partition_by_feed(symbols) do
    {options, non_options} =
      Enum.split_with(symbols, fn sym -> KiteAgentHub.Trading.OccSymbol.match?(sym) end)

    {stocks, crypto} =
      Enum.split_with(non_options, fn sym ->
        cond do
          String.contains?(sym, "/") -> false
          String.ends_with?(sym, "USDC") -> false
          String.ends_with?(sym, "USD") and String.length(sym) >= 6 -> false
          true -> true
        end
      end)

    {stocks, crypto, options}
  end

  defp disable_alpaca_live_ticks(socket) do
    Enum.each(socket.assigns[:alpaca_live_tick_subscribed_symbols] || [], fn
      {feed, sym} when is_atom(feed) ->
        Phoenix.PubSub.unsubscribe(KiteAgentHub.PubSub, AlpacaStream.topic(feed, sym))

      sym when is_binary(sym) ->
        # Backwards compat: pre-PR289 sockets stored bare symbol strings
        # assuming :stocks. New code stores {feed, symbol} tuples.
        Phoenix.PubSub.unsubscribe(KiteAgentHub.PubSub, AlpacaStream.topic(:stocks, sym))
    end)

    # NOTE: we do NOT stop the stream feed here. Other LiveViews or
    # background agents may still be subscribed. Stopping the feed is
    # a separate admin action — most disconnects (tab close, navigate
    # away) just need the LV to release its subscriptions.

    socket
    |> assign(:alpaca_live_tick_enabled, false)
    |> assign(:alpaca_live_tick_status, :off)
    |> assign(:alpaca_live_tick_subscribed_symbols, [])
    |> assign(:alpaca_live_tick_prices, %{})
  end

  defp format_oanda_error({:http, status, %{"errorMessage" => msg}}),
    do: "#{status} — #{msg}"

  defp format_oanda_error({:http, status, _}), do: "HTTP #{status}"
  defp format_oanda_error(:not_configured), do: "OANDA practice not configured"
  defp format_oanda_error(:not_a_trading_agent), do: "agent type is not 'trading'"
  defp format_oanda_error(:missing_account_id), do: "OANDA account ID missing in credentials"
  defp format_oanda_error(other), do: inspect(other)

  # ── Forex template helpers (kept here so the OANDA tab markup
  #    stays terse). Each one tolerates the loose shapes OANDA's
  #    pricing/positions payloads can take. ───────────────────────

  defp best_bid(%{} = price) do
    case Map.get(price, "bids") do
      [%{"price" => p} | _] when is_binary(p) -> p
      _ -> Oanda.field(price, "closeoutBid", nil)
    end
  end

  defp best_bid(_), do: nil

  defp best_ask(%{} = price) do
    case Map.get(price, "asks") do
      [%{"price" => p} | _] when is_binary(p) -> p
      _ -> Oanda.field(price, "closeoutAsk", nil)
    end
  end

  defp best_ask(_), do: nil

  # Spread in pips at OANDA's displayPrecision-5 default. Falls back
  # to the raw decimal difference when either side parses cleanly,
  # otherwise nil so the template can show "—".
  defp quote_spread(%{} = price) do
    with bid when is_binary(bid) <- best_bid(price),
         ask when is_binary(ask) <- best_ask(price),
         {b, _} <- Float.parse(bid),
         {a, _} <- Float.parse(ask) do
      diff = a - b
      if diff > 0, do: :erlang.float_to_binary(diff, decimals: 5), else: nil
    else
      _ -> nil
    end
  end

  defp quote_spread(_), do: nil

  # ── Forex position card helpers (msg 8983 Phorari ack) ─────────────────
  #
  # OANDA position rows carry both `long` and `short` legs in the same
  # object; the active leg is the one with non-zero units. `forex_view/2`
  # pulls that leg out and returns the fields the card needs (instrument,
  # direction, entry price, current price from the pricing map, unrealized
  # P&L in account currency, % move since entry). Returns `nil` when both
  # legs are flat so the template can skip the row.
  defp forex_view(pos, pricing_by_instrument) do
    instrument = pos["instrument"]

    leg = active_forex_leg(pos)

    if leg do
      entry = parse_oanda_float(leg["averagePrice"])
      upl = parse_oanda_float(leg["unrealizedPL"]) || 0.0
      units_signed = parse_oanda_float(leg["units"]) || 0.0
      side = if units_signed >= 0, do: "long", else: "short"
      units = abs(units_signed)
      current = forex_current_price(instrument, pricing_by_instrument) || entry

      pct_move =
        cond do
          is_number(entry) and is_number(current) and entry > 0 ->
            sign = if side == "long", do: 1.0, else: -1.0
            sign * (current - entry) / entry * 100.0

          true ->
            0.0
        end

      %{
        instrument: instrument,
        side: side,
        units: units,
        entry: entry,
        current: current,
        upl: upl,
        pct_move: pct_move
      }
    end
  end

  defp active_forex_leg(%{"long" => %{"units" => u} = leg})
       when is_binary(u) and u != "0" and u != "" and u != "0.0",
       do: leg

  defp active_forex_leg(%{"short" => %{"units" => u} = leg})
       when is_binary(u) and u != "0" and u != "" and u != "0.0",
       do: leg

  defp active_forex_leg(_), do: nil

  defp forex_current_price(instrument, pricing_by_instrument)
       when is_binary(instrument) and is_map(pricing_by_instrument) do
    case Map.get(pricing_by_instrument, instrument) do
      %{} = price ->
        bid = parse_oanda_float(best_bid(price))
        ask = parse_oanda_float(best_ask(price))

        cond do
          is_number(bid) and is_number(ask) -> (bid + ask) / 2.0
          is_number(bid) -> bid
          is_number(ask) -> ask
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp forex_current_price(_, _), do: nil

  defp parse_oanda_float(nil), do: nil

  defp parse_oanda_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_oanda_float(v) when is_float(v), do: v
  defp parse_oanda_float(v) when is_integer(v), do: v * 1.0
  defp parse_oanda_float(_), do: nil

  defp forex_fmt_money(nil), do: "—"

  defp forex_fmt_money(v) when is_number(v) do
    sign = if v >= 0, do: "+", else: "−"
    sign <> "$" <> :erlang.float_to_binary(abs(v) * 1.0, decimals: 2)
  end

  defp forex_fmt_pct(v) when is_number(v) do
    sign = if v >= 0, do: "+", else: "−"
    sign <> :erlang.float_to_binary(abs(v) * 1.0, decimals: 2) <> "%"
  end

  defp forex_fmt_price(nil), do: "—"

  defp forex_fmt_price(v) when is_number(v) do
    :erlang.float_to_binary(v * 1.0, decimals: 5)
  end

  # TradeRecord.contracts is :decimal — render without trailing zeros
  # for whole-unit forex sizes ("1000" rather than "1000.0000000").
  defp format_units(%Decimal{} = d) do
    case Decimal.to_integer(d) do
      n -> Integer.to_string(n)
    end
  rescue
    _ -> Decimal.to_string(d, :normal)
  end

  defp format_units(n) when is_integer(n), do: Integer.to_string(n)
  defp format_units(n) when is_float(n), do: Float.to_string(n)
  defp format_units(s) when is_binary(s), do: s
  defp format_units(_), do: "—"

  # Estimated USD notional for the pending trade modal. Uses the live
  # ASK for buys and BID for sells from the cached pricing payload.
  # Returns nil when we cannot derive a quote so the template hides
  # the row entirely instead of printing a misleading number.
  defp estimated_notional(%{side: side, units: units}, %{} = pricing) do
    quote =
      case side do
        "buy" -> best_ask(pricing)
        _ -> best_bid(pricing)
      end

    with q when is_binary(q) <- quote,
         {price, _} <- Float.parse(q) do
      "$" <> :erlang.float_to_binary(price * units, decimals: 2)
    else
      _ -> nil
    end
  end

  defp estimated_notional(_pending, _pricing), do: nil

  defp chart_caption("M"),
    do:
      "Each point is the mid-price (between bid and ask) at the close of a 5-minute window. Shows recent direction at a glance."

  defp chart_caption("B"),
    do:
      "Each point is the bid price (what you receive selling) at the close of a 5-minute window. Useful when planning short entries."

  defp chart_caption("A"),
    do:
      "Each point is the ask price (what you pay buying) at the close of a 5-minute window. Useful when planning long entries."

  # Short legend label for the chart price source.
  defp chart_caption_short("M"), do: "Mid"
  defp chart_caption_short("B"), do: "Bid"
  defp chart_caption_short("A"), do: "Ask"
  defp chart_caption_short(_), do: "Mid"

  defp chart_caption(_),
    do: "Each point is the closing price of a 5-minute window."

  # Async Kalshi data loading. Wrapped — the with-chain internally uses
  # {:ok, _} / {:error, _} but a raised exception from PEM decode or
  # HTTP client would propagate and crash the LV.
  def handle_info(:load_kalshi, socket) do
    socket =
      try do
        load_kalshi_data(socket)
      rescue
        _ -> assign(socket, :kalshi_data, :error)
      end

    {:noreply, socket}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp load_alpaca_data(socket, period \\ nil) do
    org = socket.assigns.organization
    period = period || socket.assigns[:alpaca_period] || "1M"

    require Logger

    case credentials_module().fetch_secret_with_env(org.id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        Logger.info(
          "DashboardLive: Alpaca credentials found, period=#{period}, env=#{env}, key_prefix=#{String.slice(key_id || "", 0..3)}"
        )

        {api_period, api_timeframe} = alpaca_period_to_api(period)

        account_result = AlpacaClient.account(key_id, secret, env)
        positions_result = AlpacaClient.positions(key_id, secret, env)

        history_result =
          AlpacaClient.portfolio_history(key_id, secret, api_period, api_timeframe, env)

        orders_result = AlpacaClient.orders(key_id, secret, 20, env)

        case account_result do
          {:ok, account} ->
            positions =
              case positions_result do
                {:ok, p} -> p
                _ -> []
              end

            {history, base_value} =
              case history_result do
                {:ok, %{points: pts, base_value: bv}} -> {pts, bv}
                # Backwards-compat in case any other caller still
                # returns the legacy list-only shape.
                {:ok, h} when is_list(h) -> {h, nil}
                _ -> {[], nil}
              end

            orders =
              case orders_result do
                {:ok, o} -> o
                _ -> []
              end

            socket
            |> assign(:alpaca_data, %{account: account, positions: positions, orders: orders})
            |> assign(:alpaca_history, history)
            |> assign(:alpaca_history_base_value, base_value)
            |> assign(:alpaca_period, period)

          {:error, :unauthorized} ->
            Logger.warning("DashboardLive: Alpaca unauthorized — keys may be expired")
            assign(socket, :alpaca_data, :unauthorized)

          {:error, reason} ->
            Logger.warning("DashboardLive: Alpaca account fetch failed: #{inspect(reason)}")
            assign(socket, :alpaca_data, :error)
        end

      {:error, :not_configured} ->
        Logger.info("DashboardLive: Alpaca credentials not configured for org #{org.id}")
        assign(socket, :alpaca_data, :not_configured)

      {:error, reason} ->
        Logger.warning("DashboardLive: Alpaca credential fetch failed: #{inspect(reason)}")
        assign(socket, :alpaca_data, :error)
    end
  end

  defp load_kalshi_data(socket) do
    org = socket.assigns.organization

    with org when not is_nil(org) <- org,
         {:ok, credentials} <- credentials_module().fetch_secret_with_env(org.id, :kalshi),
         {key_id, pem, env} <- credentials,
         {:ok, balance} <- KalshiClient.balance(key_id, pem, env),
         {:ok, positions} <- KalshiClient.positions(key_id, pem, env) do
      # Enrich each position with its market's lifecycle status + live
      # top-of-book in one batched /markets?tickers=… call. Falls back
      # to bare positions on lookup failure.
      enriched_positions =
        case KalshiClient.enrich_positions(key_id, pem, positions, env) do
          {:ok, list} -> list
          _ -> positions
        end

      # Fetch fills and orders separately — don't fail the whole tab if these error
      fills =
        case KalshiClient.fills(key_id, pem, 50, env) do
          {:ok, f} -> f
          _ -> []
        end

      orders =
        case KalshiClient.orders(key_id, pem, 20, env) do
          {:ok, o} -> o
          _ -> []
        end

      # Resting (pending) limit orders — displayed with cancel buttons.
      pending_orders =
        case KalshiClient.list_pending_orders(key_id, pem, env) do
          {:ok, p} -> p
          _ -> []
        end

      settlements =
        case KalshiClient.settlements(key_id, pem, 20, env) do
          {:ok, s} -> s
          _ -> []
        end

      portfolio_value = Enum.reduce(enriched_positions, 0.0, fn p, acc -> acc + p.value end)
      gross_settled_pnl = Enum.reduce(settlements, 0.0, fn s, acc -> acc + s.revenue end)
      # Per Kalshi's fee-rounding model, settlement payouts are fee-free
      # but the entry/exit fills carry a per-fill `fees_cents` charge.
      # Net the total fees paid against gross settlement revenue so the
      # "Settled P&L" card reflects what actually hit the balance.
      total_fees_paid =
        Enum.reduce(fills, 0.0, fn f, acc -> acc + (f.fees_cents || 0) / 100.0 end)

      total_settled_pnl = gross_settled_pnl - total_fees_paid

      assign(socket, :kalshi_data, %{
        balance: balance,
        positions: enriched_positions,
        fills: fills,
        orders: orders,
        pending_orders: pending_orders,
        settlements: settlements,
        portfolio_value: portfolio_value,
        gross_settled_pnl: gross_settled_pnl,
        total_fees_paid: total_fees_paid,
        total_settled_pnl: total_settled_pnl
      })
    else
      nil ->
        assign(socket, :kalshi_data, :error)

      {:error, :not_configured} ->
        assign(socket, :kalshi_data, :not_configured)

      {:error, :unauthorized} ->
        assign(socket, :kalshi_data, :unauthorized)

      {:error, "kalshi 401:" <> _} ->
        assign(socket, :kalshi_data, :unauthorized)

      {:error, reason} ->
        require Logger
        Logger.warning("DashboardLive: Kalshi load failed: #{inspect(reason)}")
        assign(socket, :kalshi_data, :error)

      _ ->
        require Logger
        Logger.warning("DashboardLive: Kalshi load unexpected result shape")
        assign(socket, :kalshi_data, :error)
    end
  end

  # Credentials module reference — allows PR #24 to be merged independently.
  # Raises a clear error if Credentials is not yet available.
  defp credentials_module do
    if Code.ensure_loaded?(KiteAgentHub.Credentials) do
      KiteAgentHub.Credentials
    else
      __MODULE__.CredentialsStub
    end
  end

  # Stub used before PR #24 (API key settings) is merged.
  defmodule CredentialsStub do
    def fetch_secret(_org_id, _provider), do: {:error, :not_configured}
    def fetch_secret_with_env(_org_id, _provider), do: {:error, :not_configured}
  end

  # Only trading agents have a wallet; research / conversational agents
  # intentionally have no wallet_address. Firing a balance RPC for them
  # hangs the dashboard on the "…" pulse forever because there is
  # nothing to fetch. Skip the balance task entirely when the agent
  # is not wallet-capable — the template guards on the same predicate
  # so the Wallet Balance card also doesn't render for those agents.
  # Block number is agent-agnostic and always fires.
  defp fetch_chain_data(agent) do
    if wallet_capable?(agent) do
      Task.async(fn ->
        try do
          case RPC.get_balance(agent.wallet_address, rpc_chain(agent.chain_id)) do
            {:ok, wei} -> {:wallet_balance, wei}
            _ -> {:wallet_balance, nil}
          end
        rescue
          _ -> {:wallet_balance, nil}
        end
      end)
    end

    Task.async(fn ->
      try do
        case RPC.block_number() do
          {:ok, n} -> {:block_number, n}
          _ -> {:block_number, nil}
        end
      rescue
        _ -> {:block_number, nil}
      end
    end)
  end

  defp wallet_capable?(%{agent_type: type, wallet_address: wallet}) do
    type == "trading" and is_binary(wallet) and wallet != ""
  end

  defp wallet_capable?(_), do: false

  defp agent_initials(name) when is_binary(name) do
    name
    |> String.split(~r/[-\s_]/, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp agent_initials(_), do: "?"

  defp agent_type_tint("trading"), do: "bg-emerald-500/10 border-emerald-500/20 text-emerald-400"
  defp agent_type_tint("research"), do: "bg-blue-500/10 border-blue-500/20 text-blue-400"

  defp agent_type_tint("conversational"),
    do: "bg-purple-500/10 border-purple-500/20 text-purple-400"

  defp agent_type_tint(_), do: "bg-white/5 border-white/10 text-gray-400"

  defp replace_agent(agents, updated) do
    Enum.map(agents, fn a -> if a.id == updated.id, do: updated, else: a end)
  end

  defp wei_to_eth(nil), do: nil

  # Wei → KITE display string. Uses Decimal to preserve sub-penny
  # precision so the standard 0.00001 KITE per-attestation fee
  # renders as "0.00001" instead of being truncated to "0.0000"
  # by 4-decimal Float rounding. Returns a normalized string
  # (no scientific notation) ready for HEEx interpolation.
  defp wei_to_eth(wei) when is_integer(wei) do
    wei
    |> Decimal.new()
    |> Decimal.div(Decimal.new("1000000000000000000"))
    |> Decimal.round(8)
    |> Decimal.to_string(:normal)
  end

  # Format an ERC-20 token balance from Blockscout. Blockscout returns the
  # raw integer value as a string (so it can hold uint256 amounts that
  # overflow JS numbers); we divide by 10^decimals and round to 4 places.
  # IMPORTANT: Blockscout also returns `decimals` as a STRING ("18"), not
  # an integer — :math.pow/2 crashes with "2nd argument: not a number"
  # if you forward it as-is. parse_decimals/1 coerces both shapes safely.
  defp format_token_balance(balance_str, decimals) when is_binary(balance_str) do
    try do
      case Integer.parse(balance_str) do
        {balance, _} ->
          scaled = balance / :math.pow(10, parse_decimals(decimals))
          scaled |> Float.round(4) |> to_string()

        :error ->
          "—"
      end
    rescue
      _ -> "—"
    end
  end

  defp format_token_balance(_, _), do: "—"

  defp parse_decimals(d) when is_integer(d), do: d

  defp parse_decimals(d) when is_binary(d) do
    case Integer.parse(d) do
      {n, _} -> n
      :error -> 18
    end
  end

  defp parse_decimals(_), do: 18

  # Wrap BrokerStats.live_stats in a try/rescue so a broker API failure
  # (timeout, 500, unexpected response shape) can't crash the LiveView
  # and dump the entire socket assigns into prod logs. Falls back to
  # the previous stats on the socket if available, or the empty map if
  # this is the first call. Same defensive pattern as PR #95 mount fix.
  defp safe_broker_stats(org_id, fallback) do
    KiteAgentHub.Trading.BrokerStats.live_stats(org_id)
  rescue
    e ->
      require Logger

      Logger.warning(
        "DashboardLive: BrokerStats.live_stats failed — #{Exception.message(e)}, using fallback"
      )

      fallback || empty_broker_stats()
  end

  defp empty_broker_stats do
    %{
      total_pnl: Decimal.new(0),
      total_notional: Decimal.new(0),
      win_count: 0,
      loss_count: 0,
      trade_count: 0,
      open_count: 0
    }
  end

  # Realized return as a percentage of capital deployed across settled
  # trades. Mico (msg 8986): "we don't use percentages in many places".
  # Uses Map.get so a legacy stat shape that doesn't carry
  # `:total_notional` falls through to nil gracefully instead of
  # crashing the function head — that mismatch is what surfaced as
  # "No Data" before BrokerStats started carrying the field (msg 9029).
  defp realized_return_pct(%{total_pnl: pnl} = stats) when not is_nil(pnl) do
    notional = Map.get(stats, :total_notional)

    cond do
      is_nil(notional) ->
        nil

      Decimal.eq?(notional, 0) ->
        nil

      true ->
        Decimal.div(pnl, notional)
        |> Decimal.mult(Decimal.new(100))
        |> Decimal.to_float()
        |> Float.round(2)
    end
  end

  defp realized_return_pct(_), do: nil

  defp fmt_signed_pct(nil), do: "—"

  defp fmt_signed_pct(v) when is_number(v) do
    sign = if v >= 0, do: "+", else: "−"
    sign <> :erlang.float_to_binary(abs(v) * 1.0, decimals: 2) <> "%"
  end

  # Comma-separated, no decimals for whole-dollar account-summary values.
  # Used by the Alpaca tab. Returns "—" for nil so cells never show "$"
  # alone while the broker fetch is still in flight.
  defp format_money(nil), do: "—"

  defp format_money(value) when is_number(value) do
    value
    |> Float.round(0)
    |> trunc()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_money(_), do: "—"

  # Alpaca returns multiplier as 1.0/2.0/4.0. Render compact: "1×".
  defp format_multiplier(nil), do: "—"
  defp format_multiplier(m) when is_number(m), do: "#{trunc(m)}×"
  defp format_multiplier(_), do: "—"

  # Render the held-for-orders quantity compactly. Whole numbers print
  # as integers ("5 held"); fractional shows up to 4 decimals ("0.001 held").
  defp format_held(qty) when is_number(qty) do
    if qty == trunc(qty) do
      "#{trunc(qty)}"
    else
      :erlang.float_to_binary(qty * 1.0, decimals: 4) |> String.trim_trailing("0")
    end
  end

  defp format_held(_), do: "—"

  # PR #103: helpers for the on-chain attestations summary card.
  # Both safely no-op when there's no selected agent (e.g. fresh org
  # with no agents yet) so the dashboard never crashes on first load.
  defp attestation_count(nil), do: 0

  defp attestation_count(%{id: id}) do
    try do
      Trading.count_attestations(id)
    rescue
      _ -> 0
    end
  end

  # Full (or near-full) attestation history for the Attestations tab.
  # Scoped to the selected agent; cross-agent rollups are out of scope.
  # Wrapped in try/rescue so a transient DB failure cannot crash the
  # LiveView — matches the PR #165 fetch_chain_data rescue pattern.
  defp all_attestations(nil), do: []

  defp all_attestations(%{id: id}) do
    try do
      Trading.list_recent_attestations_with_display_pnl(id, 100)
    rescue
      _ -> []
    end
  end

  defp recent_attestations(nil), do: []

  defp recent_attestations(%{id: id}) do
    try do
      Trading.list_recent_attestations(id, 5)
    rescue
      _ -> []
    end
  end

  # Render the running KITE total paid to the treasury. Each attestation
  # is exactly 0.00001 KITE (KiteAttestationWorker @attestation_amount_wei
  # = 1e13 wei = 1e-5 KITE post-PR #106). Format with 5 decimals so a
  # single attestation reads as "0.00001" not "0.0".
  defp format_attestation_fee(count) when is_integer(count) and count >= 0 do
    :erlang.float_to_binary(count * 0.00001, decimals: 5)
  end

  defp format_attestation_fee(_), do: "0.00000"

  # Per-trade attestation transfer amount — the fixed 0.00001 KITE that
  # KiteAttestationWorker sends to the treasury on every settlement.
  # Hardcoded server constant; `tx.value / 10^18` with no user input.
  @per_trade_fee_kite "0.00001"
  defp per_trade_fee_kite, do: @per_trade_fee_kite

  # Render a Decimal P&L with up to 8 fractional digits, stripping trailing
  # zeros. Mico 9891: at the prior 4-decimal precision a tiny attestation
  # amount like 0.00001 KITE truncated to "0.0000" in the trade feed.
  # Using a wider precision with trim keeps regular dollar P&L compact
  # ("1.5" instead of "1.50000000") while exposing sub-cent values.
  defp format_compact_pnl(nil), do: "—"

  defp format_compact_pnl(%Decimal{} = d) do
    d
    |> Decimal.round(8)
    |> Decimal.to_string(:normal)
    |> trim_trailing_zeros()
  end

  defp format_compact_pnl(n) when is_integer(n), do: format_compact_pnl(n / 1.0)
  defp format_compact_pnl(n) when is_float(n), do: format_compact_pnl(Decimal.from_float(n))

  defp trim_trailing_zeros(str) do
    if String.contains?(str, ".") do
      str |> String.trim_trailing("0") |> String.trim_trailing(".")
    else
      str
    end
  end

  # Static gas-cost estimate per attestation tx. Computed from the
  # hardcoded KiteAttestationWorker @gas_limit (30_000) and the
  # TxSigner default gas_price (1 gwei = 10^9 wei). CyberSec-cleared
  # for display use because every input is a compile-time constant —
  # no receipt data, no user-supplied value (msg 6420).
  #
  # 30_000 gas × 10^9 wei/gas ÷ 10^18 wei/KITE = 3e-5 KITE = 0.00003.
  # Labeled "~approx" in the UI since live gas_price fluctuates.
  @est_gas_kite "0.00003"
  defp est_gas_kite, do: @est_gas_kite

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <%!-- Top nav bar --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center justify-between">
            <.link
              navigate={~p"/dashboard"}
              class="flex items-center gap-3 hover:opacity-80 transition-opacity"
            >
              <.kah_logo class="w-8 h-8 shrink-0 drop-shadow-[0_0_10px_rgba(34,197,94,0.35)]" />
              <div>
                <span class="text-sm font-black text-white tracking-tight uppercase">
                  Kite Agent Hub
                </span>
                <span class="text-xs text-gray-400 font-mono tracking-widest uppercase hidden sm:inline truncate max-w-[120px] sm:max-w-none ml-2">
                  {if @organization, do: @organization.name, else: "No workspace"}
                </span>
              </div>
            </.link>
            <div class="flex items-center gap-4">
              <%!-- Persistent "agents make mistakes" reminder (Mico 10039).
                   Always visible in the top nav next to the BLOCK ticker.
                   Keyed to the `text-amber-200/90` + `bg-amber-500/[0.06]`
                   + `border-amber-500/40` palette the risk-disclosure band
                   already uses; those have explicit `html[data-theme="light"]`
                   overrides (assets/css/app.css:332-343) so the pill stays
                   legible on the cream canvas (Mico 10094). Original
                   `text-yellow-300` was dark-canvas-only and washed out
                   on white. --%>
              <div
                class="hidden md:inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full border border-amber-500/40 bg-amber-500/[0.06] text-[10px] uppercase tracking-widest text-amber-200/90 whitespace-nowrap"
                title="Review every trade and chat — these are autonomous agents and they make mistakes."
              >
                <span aria-hidden="true">⚠</span>
                <span>Agents make mistakes</span>
              </div>
              <%= if @block_number do %>
                <div class="hidden sm:flex items-center gap-2 px-3 py-1.5 rounded-full border border-white/10 bg-white/[0.02] shadow-[0_0_10px_rgba(255,255,255,0.02)]">
                  <span class="w-1.5 h-1.5 rounded-full bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse">
                  </span>
                  <span class="text-xs font-mono text-gray-300 tracking-wider">
                    BLOCK {@block_number}
                  </span>
                </div>
              <% end %>
              <.link
                navigate={~p"/trades"}
                class="hidden sm:block text-xs text-gray-400 hover:text-white transition-colors font-semibold uppercase tracking-widest"
              >
                Trades
              </.link>
              <.link
                navigate={~p"/agents/new"}
                class="inline-flex items-center gap-1.5 px-4 py-1.5 rounded-xl border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] text-white text-xs font-bold transition-all uppercase tracking-widest"
              >
                <.icon name="hero-plus" class="w-3.5 h-3.5" /> New Agent
              </.link>
              <%!-- Mobile menu button (hidden on sm+) --%>
              <button
                class="sm:hidden inline-flex items-center justify-center w-9 h-9 rounded-lg border border-white/20 bg-white/[0.07] text-gray-300 hover:text-white hover:bg-white/[0.12] transition-all"
                phx-click={JS.toggle(to: "#mobile-nav-drawer")}
                aria-label="Menu"
              >
                <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
              </button>
              <%!-- Agent Context moved to per-agent Settings (Mico 9898) — was misleading at the dashboard-global level since context is per agent. --%>
              <.link
                navigate={~p"/users/settings"}
                class="hidden sm:inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs uppercase tracking-widest text-gray-400 hover:text-white transition-all"
              >
                <.icon name="hero-cog-6-tooth" class="w-3.5 h-3.5" /> Settings
              </.link>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="hidden sm:block text-xs text-gray-500 hover:text-gray-300 transition-colors uppercase font-semibold tracking-widest"
              >
                Sign out
              </.link>
            </div>
          </div>
        </div>

        <%!-- Mobile nav drawer (toggle via hamburger, hidden on sm+) --%>
        <div
          id="mobile-nav-drawer"
          class="hidden sm:hidden border-b border-white/10 bg-[#0a0a0f]/95 backdrop-blur-md z-10"
        >
          <div class="px-4 py-3 space-y-1">
            <%= if @block_number do %>
              <div class="flex items-center gap-3 px-3 py-3 min-h-[44px]">
                <span class="w-2 h-2 rounded-full bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse shrink-0">
                </span>
                <span class="text-xs font-mono text-gray-300 tracking-wider">
                  BLOCK {@block_number}
                </span>
              </div>
            <% end %>
            <%!-- Agent Context moved to /users/settings/agents per-agent panel (Mico 9898). --%>
            <.link
              navigate={~p"/users/settings"}
              class="flex items-center gap-3 px-3 py-3 rounded-xl text-gray-300 hover:bg-white/[0.05] transition-colors min-h-[44px]"
            >
              <.icon name="hero-cog-6-tooth" class="w-5 h-5 shrink-0" />
              <span class="text-sm font-semibold">Settings</span>
            </.link>
            <.link
              href={~p"/users/log-out"}
              method="delete"
              class="flex items-center gap-3 px-3 py-3 rounded-xl text-gray-400 hover:bg-white/[0.05] transition-colors min-h-[44px]"
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-5 h-5 shrink-0" />
              <span class="text-sm font-semibold">Sign out</span>
            </.link>
          </div>
        </div>
        <%!-- Tab navigation --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/60 backdrop-blur-sm px-4 sm:px-6 lg:px-8">
          <nav
            class="flex gap-1 overflow-x-auto [&::-webkit-scrollbar]:hidden [-ms-overflow-style:none] [scrollbar-width:none]"
            id="dashboard-tabs"
          >
            <%!-- Per-venue connector logos (nil for non-venue tabs). Rendered
                 inline before the label so users see the same brand mark
                 they get from the home brand belt pre-signin. --%>
            <%= for {label, tab_key, logo} <- [
              {"Overview", "overview", nil},
              {"Attestations", "attestations", nil},
              {"Kite Wallet", "wallet", "/images/connectors/kite_chain.png"},
              {"EdgeScorer", "edge_scorer", nil},
              {"Alpaca", "alpaca", "/images/connectors/alpaca.png"},
              {"Kalshi", "kalshi", "/images/connectors/kalshi.png"},
              {"Polymarket", "polymarket", "/images/connectors/polymarket.png"},
              {"ForEx", "forex", "/images/connectors/oanda.png"},
              {"Portfolio", "portfolio", nil},
              {"Agent Logs", "logs", nil}
            ] do %>
              <button
                id={"tab-#{tab_key}"}
                phx-click="switch_tab"
                phx-value-tab={tab_key}
                class={[
                  "inline-flex items-center gap-1.5 px-3 py-2 sm:px-4 sm:py-3 text-[10px] sm:text-xs uppercase tracking-widest transition-all whitespace-nowrap",
                  dashboard_tab_class(tab_key, @active_tab == String.to_atom(tab_key))
                ]}
              >
                <img :if={logo} src={logo} alt="" class="h-5 w-5 object-contain" />
                {label}
              </button>
            <% end %>
          </nav>
        </div>

        <%= if @agents == [] do %>
          <%!-- ═══════════════ EMPTY STATE — first-time user ═══════════════ --%>
          <div class="w-full px-4 sm:px-6 lg:px-8 py-20 text-center relative overflow-hidden">
            <div class="absolute inset-0 flex items-center justify-center pointer-events-none">
              <div class="w-[600px] h-[600px] rounded-full bg-white/[0.02] blur-3xl absolute top-10 left-1/2 -translate-x-1/2">
              </div>
            </div>
            <div class="relative z-10 max-w-4xl mx-auto">
              <div class="w-20 h-20 rounded-2xl border border-white/10 bg-white/[0.03] flex items-center justify-center mx-auto mb-8 shadow-[0_0_30px_rgba(255,255,255,0.05)]">
                <.icon name="hero-cpu-chip" class="w-10 h-10 text-white" />
              </div>
              <h1 class="text-5xl font-black text-white mb-6 tracking-tight">
                Autonomous AI Trading.<br />
                <span class="text-gray-400">
                  On-Chain. Unstoppable.
                </span>
              </h1>
              <p class="text-lg text-gray-500 max-w-xl mx-auto mb-12 font-light">
                Deploy a trading agent powered by Claude AI. It reads market data, generates signals, and executes trades on Kite chain — around the clock, fully autonomous.
              </p>

              <div class="grid grid-cols-1 sm:grid-cols-3 gap-6 mb-12">
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 text-left hover:bg-white/[0.04] transition-all">
                  <div class="w-10 h-10 rounded-xl border border-white/10 bg-black flex items-center justify-center mb-4">
                    <span class="text-lg font-black text-white">1</span>
                  </div>
                  <h3 class="text-sm font-bold text-white mb-2">Create an Agent</h3>
                  <p class="text-xs text-gray-400 leading-relaxed font-light">
                    Name your agent, set spending limits, and provide your Kite wallet address. Takes 30 seconds.
                  </p>
                </div>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 text-left hover:bg-white/[0.04] transition-all">
                  <div class="w-10 h-10 rounded-xl border border-white/10 bg-black flex items-center justify-center mb-4">
                    <span class="text-lg font-black text-white">2</span>
                  </div>
                  <h3 class="text-sm font-bold text-white mb-2">Deploy a Vault</h3>
                  <p class="text-xs text-gray-400 leading-relaxed font-light">
                    Deploy the TradingAgentVault contract on Kite chain. Your wallet signing keys stay on your machine.
                  </p>
                </div>
                <div class="rounded-2xl border border-[#22c55e]/30 bg-[#22c55e]/[0.05] backdrop-blur-md p-6 text-left shadow-[0_0_15px_rgba(34,197,94,0.1)]">
                  <div class="w-10 h-10 rounded-xl border border-[#22c55e]/50 bg-black flex items-center justify-center mb-4 text-[#22c55e] shadow-[0_0_10px_rgba(34,197,94,0.2)]">
                    <span class="text-lg font-black">3</span>
                  </div>
                  <h3 class="text-sm font-bold text-white mb-2">Watch It Trade</h3>
                  <p class="text-xs text-gray-400 leading-relaxed font-light">
                    Activate the agent. Your agent watches the market, places trades on your broker account, and posts attestations to Kite chain.
                  </p>
                </div>
              </div>

              <.link
                navigate={~p"/agents/new"}
                class="inline-flex items-center gap-2 px-10 py-4 rounded-xl border border-white/10 bg-white/[0.08] hover:bg-white/[0.12] text-white text-base font-bold transition-all shadow-[0_0_20px_rgba(255,255,255,0.05)] hover:-translate-y-0.5 transform tracking-wide"
              >
                <.kah_logo class="w-5 h-5 shrink-0" /> Launch Your First Agent
              </.link>
              <p class="text-xs text-gray-600 mt-6 font-mono">
                Chain ID {KiteAgentHub.Kite.ChainId.default()} · Powered by Claude
              </p>
            </div>
          </div>
        <% else %>
          <%!-- ═══════════════ MAIN DASHBOARD ═══════════════ --%>
          <%= if @active_tab == :overview do %>
            <div class="w-full px-4 sm:px-6 lg:px-8 py-6 flex flex-col md:flex-row gap-6">
              <%!-- ── Sidebar: Agent List ── --%>
              <div class="w-full md:w-48 lg:w-72 shrink-0 space-y-4">
                <div class="flex items-center justify-between px-2">
                  <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">Agents</h2>
                  <span class="text-xs text-gray-600 font-mono tracking-wider">
                    {length(@agents)} total
                  </span>
                </div>

                <div class="space-y-2">
                  <%= for agent <- @agents do %>
                    <.link
                      patch={~p"/dashboard?agent_id=#{agent.id}"}
                      class={[
                        "block rounded-xl p-4 transition-all border group",
                        @selected_agent && @selected_agent.id == agent.id &&
                          "border-emerald-500/40 bg-emerald-500/10 shadow-[0_0_20px_rgba(34,197,94,0.20)]",
                        (!@selected_agent || @selected_agent.id != agent.id) &&
                          "border-white/5 bg-white/[0.01] hover:border-white/10 hover:bg-white/[0.03]"
                      ]}
                    >
                      <div class="flex items-start justify-between gap-2 mb-2">
                        <div class="flex items-center gap-3 min-w-0">
                          <span class={[
                            "w-8 h-8 rounded-[10px] border flex items-center justify-center shrink-0 text-[11px] font-black tracking-wide",
                            agent_type_tint(agent.agent_type)
                          ]}>
                            {agent_initials(agent.name)}
                          </span>
                          <span class={[
                            "text-sm font-bold truncate tracking-wide transition-colors",
                            @selected_agent && @selected_agent.id == agent.id &&
                              "text-emerald-700 dark:text-emerald-300",
                            (!@selected_agent || @selected_agent.id != agent.id) &&
                              "text-gray-400 group-hover:text-gray-200"
                          ]}>
                            {agent.name}
                          </span>
                        </div>
                        <span class={[
                          "w-2 h-2 rounded-full shrink-0 mt-1",
                          agent.status == "active" && "bg-[#22c55e] shadow-[0_0_8px_#22c55e]",
                          agent.status == "paused" && "bg-yellow-400",
                          agent.status == "pending" && "bg-gray-500",
                          agent.status == "error" && "bg-[#ef4444]"
                        ]}>
                        </span>
                      </div>
                      <p class="text-xs text-gray-600 font-mono truncate mb-3">
                        {String.slice(agent.wallet_address || "", 0, 12)}…
                      </p>
                      <div class="flex items-center gap-2">
                        <span class={[
                          "text-[10px] px-2 py-0.5 rounded-full border uppercase tracking-widest font-bold",
                          agent.status == "active" &&
                            "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e]",
                          agent.status == "paused" &&
                            "bg-yellow-500/10 border-yellow-500/20 text-yellow-400",
                          agent.status == "pending" &&
                            "bg-gray-500/10 border-gray-500/20 text-gray-400",
                          agent.status == "error" &&
                            "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]"
                        ]}>
                          {agent.status}
                        </span>
                        <%= if agent.agent_type do %>
                          <span class={[
                            "text-[10px] px-2 py-0.5 rounded border uppercase tracking-widest font-bold",
                            case agent.agent_type do
                              "trading" -> "bg-emerald-500/10 border-emerald-500/20 text-emerald-400"
                              "research" -> "bg-blue-500/10 border-blue-500/20 text-blue-400"
                              _ -> "bg-purple-500/10 border-purple-500/20 text-purple-400"
                            end
                          ]}>
                            {agent.agent_type}
                          </span>
                        <% end %>
                      </div>
                    </.link>
                  <% end %>
                </div>

                <.link
                  navigate={~p"/agents/new"}
                  class="flex items-center justify-center gap-2 w-full rounded-xl py-4 border border-dashed border-white/10 bg-white/[0.01] hover:bg-white/[0.03] hover:border-white/20 text-gray-500 hover:text-white transition-all text-xs uppercase tracking-widest"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Add Agent
                </.link>
                <%!-- Connect CTA: solid emerald fill so the body copy stays
                readable in both light and dark themes (Mico 9924). Headline
                arrow removed — only the pulsing ↓ remains. --%>
                <a
                  href="#connect-your-agent"
                  class="mt-3 group block w-full rounded-xl bg-emerald-500 hover:bg-emerald-400 px-5 py-5 shadow-[0_0_32px_rgba(34,197,94,0.28)] hover:shadow-[0_0_44px_rgba(34,197,94,0.45)] transition-all"
                >
                  <div class="flex items-center justify-between gap-4">
                    <div class="min-w-0">
                      <p class="text-[11px] font-black text-white/80 uppercase tracking-widest mb-1">
                        Ready to trade?
                      </p>
                      <p class="text-base sm:text-lg font-black text-white leading-snug">
                        Set up your agent below to start
                      </p>
                      <p class="text-xs text-white/90 mt-1 leading-snug">
                        Copy your agent's prompt into Claude Code or Codex Terminal and it starts running.
                      </p>
                    </div>
                    <span class="text-3xl text-white animate-pulse drop-shadow-[0_0_10px_rgba(255,255,255,0.6)]">
                      ↓
                    </span>
                  </div>
                </a>
              </div>

              <%!-- ── Main Panel ── --%>
              <div class="flex-1 space-y-6 min-w-0">
                <%= if @selected_agent do %>
                  <%!-- Agent header --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                    <div class="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
                      <div>
                        <div class="flex items-center gap-4 mb-2">
                          <h2 class="text-2xl font-black text-white tracking-tight">
                            {@selected_agent.name}
                          </h2>
                          <span class={[
                            "inline-flex items-center gap-2 px-3 py-1 rounded-full border text-[10px] uppercase tracking-widest font-bold",
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
                              @selected_agent.status == "pending" && "bg-gray-400 animate-pulse",
                              @selected_agent.status == "error" && "bg-[#ef4444]"
                            ]}>
                            </span>
                            {@selected_agent.status}
                          </span>
                        </div>
                        <p class="text-xs font-mono text-gray-500 select-all">
                          {@selected_agent.wallet_address}
                        </p>
                      </div>
                      <div class="flex items-center gap-3 shrink-0">
                        <%= if @selected_agent.status == "active" do %>
                          <button
                            phx-click="pause_agent"
                            class="px-4 py-2 rounded-xl border border-yellow-500/30 bg-yellow-500/10 hover:bg-yellow-500/20 text-yellow-500 text-xs uppercase tracking-widest transition-all"
                          >
                            Pause
                          </button>
                        <% end %>
                        <%= if @selected_agent.status == "paused" do %>
                          <button
                            phx-click="resume_agent"
                            class="px-4 py-2 rounded-xl border border-[#22c55e]/30 bg-[#22c55e]/10 hover:bg-[#22c55e]/20 text-[#22c55e] text-xs uppercase tracking-widest transition-all"
                          >
                            Resume
                          </button>
                        <% end %>
                      </div>
                    </div>
                  </div>

                  <%!-- Stats row --%>
                  <div class="grid grid-cols-2 md:grid-cols-4 gap-3 sm:gap-4">
                    <%!-- Realized P&L --%>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 relative overflow-hidden group">
                      <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                        Realized P&L
                      </p>
                      <%= if @pnl_stats && @pnl_stats.trade_count > 0 do %>
                        <% return_pct = realized_return_pct(@pnl_stats) %>
                        <div class="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                          <p class={[
                            "text-2xl sm:text-3xl font-black tracking-tight break-all transition-all duration-300",
                            Decimal.gt?(@pnl_stats.total_pnl, 0) &&
                              "text-[#22c55e] drop-shadow-[0_0_15px_rgba(34,197,94,0.4)]",
                            Decimal.lt?(@pnl_stats.total_pnl, 0) &&
                              "text-[#ef4444] drop-shadow-[0_0_15px_rgba(239,68,68,0.4)]",
                            Decimal.eq?(@pnl_stats.total_pnl, 0) && "text-gray-300"
                          ]}>
                            {if Decimal.gt?(@pnl_stats.total_pnl, 0), do: "+"}${Decimal.round(
                              @pnl_stats.total_pnl,
                              4
                            )}
                          </p>
                          <%= if return_pct do %>
                            <% pct_chip_cls =
                              cond do
                                return_pct > 0 ->
                                  "text-[#22c55e] bg-[#22c55e]/[0.10] border-[#22c55e]/40"

                                return_pct < 0 ->
                                  "text-[#ef4444] bg-[#ef4444]/[0.10] border-[#ef4444]/40"

                                true ->
                                  "text-gray-300 bg-white/[0.04] border-white/15"
                              end %>
                            <span class={"px-2 py-0.5 rounded-full text-xs font-mono font-bold border " <> pct_chip_cls}>
                              {fmt_signed_pct(return_pct)}
                            </span>
                          <% end %>
                        </div>
                        <p class="text-[10px] text-gray-500 mt-2 font-mono uppercase tracking-widest">
                          {@pnl_stats.trade_count} Settled Trades
                        </p>
                      <% else %>
                        <p class="text-2xl sm:text-3xl font-black text-gray-700 tracking-tight">
                          $0.00
                        </p>
                        <p class="text-[10px] text-gray-600 mt-2 font-mono uppercase tracking-widest">
                          No Trades
                        </p>
                      <% end %>
                    </div>

                    <%!-- Return % — replaces the old Win Rate card.
                         Total realized P&L as a percentage of capital
                         deployed (fill_price × contracts summed across
                         settled rows). Mico flagged 2026-05-11 (msg 8986)
                         that win/loss reads less natural than %. --%>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                      <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                        Return %
                      </p>
                      <% return_pct = @pnl_stats && realized_return_pct(@pnl_stats) %>
                      <%= cond do %>
                        <% @pnl_stats && @pnl_stats.trade_count > 0 && return_pct -> %>
                          <p class={[
                            "text-2xl sm:text-3xl font-black tracking-tight break-all",
                            return_pct > 0 &&
                              "text-[#22c55e] drop-shadow-[0_0_15px_rgba(34,197,94,0.4)]",
                            return_pct < 0 &&
                              "text-[#ef4444] drop-shadow-[0_0_15px_rgba(239,68,68,0.4)]",
                            return_pct == 0.0 && "text-gray-300"
                          ]}>
                            {fmt_signed_pct(return_pct)}
                          </p>
                          <p class="text-[10px] text-gray-500 mt-2 font-mono uppercase tracking-widest">
                            on ${Decimal.round(@pnl_stats.total_notional, 2)} traded
                          </p>
                        <% true -> %>
                          <p class="text-2xl sm:text-3xl font-black text-gray-700 tracking-tight">
                            —
                          </p>
                          <p class="text-[10px] text-gray-600 mt-2 font-mono tracking-widest uppercase">
                            No Data
                          </p>
                      <% end %>
                    </div>

                    <%!-- Open Positions --%>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                      <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                        Open Positions
                      </p>
                      <p class="text-2xl sm:text-3xl font-black text-white tracking-tight break-all">
                        {if @pnl_stats, do: @pnl_stats.open_count, else: 0}
                      </p>
                    </div>

                    <%!-- Wallet Balance — hidden for non-trading agents or
                       trading agents without a wallet configured.
                       Otherwise the card sits on "…" forever because there
                       is no wallet to query. --%>
                    <div
                      :if={wallet_capable?(@selected_agent)}
                      class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6"
                    >
                      <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                        Wallet Balance
                      </p>
                      <%= if @wallet_balance_eth do %>
                        <p class="text-2xl sm:text-3xl font-black text-white tracking-tight break-all">
                          {@wallet_balance_eth}
                        </p>
                        <p class="text-[10px] text-gray-500 mt-2 font-mono uppercase tracking-widest">
                          KITE ({KiteAgentHub.Kite.ChainId.label(
                            @selected_agent && @selected_agent.chain_id
                          )})
                        </p>
                      <% else %>
                        <p class="text-2xl sm:text-3xl font-black text-gray-700 tracking-tight animate-pulse">
                          …
                        </p>
                        <p class="text-[10px] text-gray-600 mt-2 font-mono uppercase tracking-widest">
                          Fetching
                        </p>
                      <% end %>
                    </div>
                  </div>

                  <%!-- PR #103: Kite Chain Attestations summary banner.
                     This is the demo's headline proof: every settled trade
                     produces a verifiable on-chain receipt. Judges scrolling
                     the dashboard see this card before the trade list. --%>
                  <div class="rounded-2xl border border-emerald-500/30 bg-gradient-to-r from-emerald-500/[0.06] to-emerald-500/[0.02] backdrop-blur-md p-6">
                    <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-4">
                      <div class="flex items-start gap-4">
                        <div class="h-8 w-8 rounded-full bg-emerald-500/[0.18] flex items-center justify-center shrink-0 text-emerald-400 text-base font-black shadow-[0_0_10px_rgba(34,197,94,0.3)]">
                          ✓
                        </div>
                        <div class="min-w-0">
                          <p class="text-[10px] text-emerald-400 uppercase tracking-widest mb-1">
                            Kite Chain Attestations
                          </p>
                          <p class="text-2xl sm:text-3xl font-black text-white tracking-tight">
                            {@attestation_count}
                            <span class="text-base font-mono text-gray-500">on-chain receipts</span>
                          </p>
                          <div class="text-[11px] text-gray-400 mt-1 font-mono space-y-0.5">
                            <p>Per-trade fee: {per_trade_fee_kite()} KITE</p>
                            <p class="text-gray-500">~Est. gas per tx: {est_gas_kite()} KITE</p>
                            <p>
                              Total attestation fees paid: {format_attestation_fee(@attestation_count)} KITE
                            </p>
                          </div>
                        </div>
                      </div>
                      <%= if @selected_agent && @selected_agent.wallet_address do %>
                        <a
                          href={
                            explorer_address_url(
                              @selected_agent.wallet_address,
                              @selected_agent.chain_id
                            )
                          }
                          target="_blank"
                          rel="noopener noreferrer"
                          class="inline-flex items-center gap-2 px-4 py-2 rounded-xl border border-emerald-500/30 bg-emerald-500/10 hover:bg-emerald-500/20 text-emerald-300 hover:text-emerald-200 text-xs uppercase tracking-widest transition-all whitespace-nowrap"
                        >
                          View All on Kitescan →
                        </a>
                      <% end %>
                    </div>

                    <%= if @recent_attestations != [] do %>
                      <div class="mt-4 pt-4 border-t border-emerald-500/10 space-y-2">
                        <p class="text-[10px] text-gray-500 uppercase tracking-widest">
                          Latest receipts
                        </p>
                        <%= for tx <- @recent_attestations do %>
                          <a
                            href={explorer_tx_url(tx.attestation_tx_hash, @selected_agent.chain_id)}
                            target="_blank"
                            rel="noopener noreferrer"
                            class="flex items-center justify-between gap-2 text-[11px] font-mono text-gray-400 hover:text-emerald-300 transition-colors"
                          >
                            <span class="truncate">
                              {tx.market} {tx.action}
                            </span>
                            <span class="text-emerald-500/70 truncate">
                              {String.slice(tx.attestation_tx_hash, 0, 10)}…{String.slice(
                                tx.attestation_tx_hash,
                                -6,
                                6
                              )}
                            </span>
                          </a>
                        <% end %>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Vault address strip --%>
                  <div class="flex flex-wrap items-center gap-x-6 gap-y-3 rounded-2xl border border-white/5 bg-white/[0.01] px-6 py-4">
                    <span class="text-[10px] text-gray-600 uppercase tracking-widest">
                      Vault
                    </span>
                    <div class="flex items-baseline gap-2 min-w-0">
                      <span class="text-sm font-mono text-gray-400 truncate select-all">
                        {if @selected_agent.vault_address,
                          do: String.slice(@selected_agent.vault_address, 0, 18) <> "…",
                          else: "Not deployed"}
                      </span>
                    </div>
                  </div>

                  <%!-- Vault Activation Banner (trading agents only) --%>
                  <%= if @selected_agent.status == "pending" and (@selected_agent.agent_type == "trading" or is_nil(@selected_agent.agent_type)) do %>
                    <div class="rounded-2xl border border-gray-600/30 bg-gray-600/5 p-6 backdrop-blur-md">
                      <div class="flex flex-col md:flex-row items-start md:items-center gap-6">
                        <div class="h-12 w-12 rounded-xl border border-gray-500/30 bg-gray-500/10 flex items-center justify-center shrink-0">
                          <.icon name="hero-command-line" class="w-6 h-6 text-gray-300" />
                        </div>
                        <div class="flex-1 min-w-0 space-y-3">
                          <div>
                            <h3 class="text-base font-bold text-white tracking-tight">
                              Vault not deployed
                            </h3>
                            <p class="text-[11px] text-gray-400 tracking-wide mt-1">
                              Deploy the vault contract, then paste the address below to go live.
                            </p>
                          </div>
                          <.form
                            for={@vault_form}
                            phx-submit="activate_vault"
                            class="flex flex-col sm:flex-row gap-3"
                          >
                            <input
                              type="text"
                              name="vault[vault_address]"
                              placeholder="0x vault contract address"
                              class="flex-1 rounded-xl border border-white/10 bg-black/50 px-4 py-3 text-white font-mono text-sm placeholder-gray-600 focus:outline-none focus:border-white/30 focus:ring-1 focus:ring-white/30 transition-all shadow-inner"
                            />
                            <button
                              type="submit"
                              phx-disable-with="Activating…"
                              class="px-8 py-3 rounded-xl border border-white/10 bg-white text-black uppercase tracking-widest text-xs hover:bg-gray-200 transition-colors whitespace-nowrap shadow-[0_0_20px_rgba(255,255,255,0.2)]"
                            >
                              Activate Vault
                            </button>
                          </.form>
                        </div>
                      </div>
                    </div>
                  <% end %>

                  <%!-- Live Trade Feed --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md overflow-hidden">
                    <div class="flex items-center justify-between px-6 py-5 border-b border-white/10">
                      <h3 class="text-sm font-black text-white uppercase tracking-widest">
                        Live Trade Feed
                      </h3>
                      <div class="flex items-center gap-4">
                        <.link
                          navigate={~p"/trades"}
                          class="text-[10px] text-gray-500 hover:text-white uppercase tracking-widest font-bold transition-colors"
                        >
                          View all ↗
                        </.link>
                        <div class="flex items-center gap-2 px-2.5 py-1 rounded bg-[#22c55e]/10 border border-[#22c55e]/20">
                          <span class="w-1.5 h-1.5 rounded-full bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse">
                          </span>
                          <span class="text-[10px] font-bold text-[#22c55e] uppercase tracking-widest">
                            Live
                          </span>
                        </div>
                      </div>
                    </div>

                    <div id="trades" phx-update="stream" class="divide-y divide-white/5">
                      <div
                        id="trades-empty-state"
                        class="hidden only:flex flex-col items-center justify-center py-20 px-4 text-center"
                      >
                        <div class="w-12 h-12 rounded-xl border border-white/5 bg-white/[0.02] flex items-center justify-center mb-4">
                          <.icon name="hero-chart-bar" class="w-6 h-6 text-gray-600" />
                        </div>
                        <p class="text-sm font-bold text-gray-400">No trades yet</p>
                        <p class="text-xs text-gray-600 mt-2 font-mono">
                          <%= if @selected_agent.status == "active" do %>
                            Agent is scanning for signals
                          <% else %>
                            Deploy vault to initialize trading
                          <% end %>
                        </p>
                      </div>

                      <%= for {id, trade} <- @streams.trades do %>
                        <div
                          id={id}
                          class="flex flex-col sm:flex-row sm:items-center gap-4 px-6 py-4 hover:bg-white/[0.02] transition-colors group"
                        >
                          <%!-- Action indicator --%>
                          <div class="shrink-0 flex sm:block items-center justify-between w-full sm:w-16">
                            <span class={[
                              "w-full inline-flex items-center justify-center px-2 py-1.5 rounded-lg border text-[10px] uppercase tracking-widest",
                              trade.action == "buy" &&
                                "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e] group-hover:bg-[#22c55e]/20",
                              trade.action == "sell" &&
                                "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444] group-hover:bg-[#ef4444]/20"
                            ]}>
                              {trade.action || "UNKN"}
                            </span>
                          </div>

                          <%!-- Market info --%>
                          <div class="flex-1 min-w-0">
                            <div class="flex items-center gap-2 min-w-0">
                              <p
                                class="text-base font-black text-white tracking-tight truncate"
                                title={trade.market}
                              >
                                {truncate_market(trade.market)}
                              </p>
                              <span class={[
                                "text-[9px] px-1.5 py-0.5 rounded border uppercase tracking-widest font-bold",
                                trade.status == "open" &&
                                  "bg-blue-500/10 border-blue-500/20 text-blue-400",
                                trade.status == "settled" &&
                                  "bg-gray-500/10 border-gray-500/20 text-gray-400",
                                trade.status == "cancelled" &&
                                  "bg-yellow-500/10 border-yellow-500/20 text-yellow-500",
                                trade.status == "failed" &&
                                  "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]"
                              ]}>
                                {trade.status}
                              </span>
                            </div>
                            <p class="text-[11px] text-gray-500 font-mono mt-0.5">
                              {trade.contracts}x contracts
                            </p>
                          </div>

                          <%!-- Fill & PNL --%>
                          <div class="flex sm:flex-col items-end justify-between sm:justify-center gap-2 sm:gap-1">
                            <p class="text-sm font-mono font-bold text-gray-300">
                              ${trade.fill_price}
                            </p>
                            <%= if trade.realized_pnl do %>
                              <p class={[
                                "text-sm font-bold font-mono",
                                Decimal.gt?(trade.realized_pnl, 0) && "text-[#22c55e]",
                                Decimal.lt?(trade.realized_pnl, 0) && "text-[#ef4444]",
                                Decimal.eq?(trade.realized_pnl, 0) && "text-gray-500"
                              ]}>
                                {if Decimal.gt?(trade.realized_pnl, 0), do: "+"}${format_compact_pnl(
                                  trade.realized_pnl
                                )}
                              </p>
                            <% end %>
                            <%!-- PR #101: Kite chain attestation receipt. Every settled
                               trade gets a tiny on-chain transfer to a treasury via
                               KiteAttestationWorker; the resulting tx hash is the
                               judges' "settles on Kite chain + attestation" proof. --%>
                            <%= if trade.attestation_tx_hash do %>
                              <a
                                href={
                                  explorer_tx_url(trade.attestation_tx_hash, @selected_agent.chain_id)
                                }
                                target="_blank"
                                rel="noopener noreferrer"
                                class="text-[10px] text-emerald-400 hover:text-emerald-300 font-mono inline-flex items-center gap-1"
                                title={"Kite chain attestation: " <> trade.attestation_tx_hash}
                              >
                                ✓ on-chain
                              </a>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>

                <%!-- Connect Your Agent — per-track instructions, secrets masked by default --%>
                <div
                  id="connect-your-agent"
                  class="scroll-mt-24 rounded-2xl border border-white/10 bg-white/[0.02] p-6 space-y-4"
                >
                  <div>
                    <h3 class="text-xs font-black text-white uppercase tracking-widest mb-2">
                      Connect Your Agent
                    </h3>
                    <p class="text-[11px] text-gray-400 leading-relaxed">
                      Choose your runner below — Claude Code or Codex Terminal. Each has its own instructions; the token below is shared.
                    </p>
                  </div>

                  <%!-- Agent Token (masked by default) --%>
                  <div>
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-[10px] font-black text-gray-400 uppercase tracking-widest">
                        Agent Token · Secret
                      </span>
                      <div class="flex items-center gap-3">
                        <button
                          id={"copy-agent-token-#{@selected_agent.id}"}
                          phx-hook="CopyToClipboard"
                          data-text={@selected_agent.api_token || ""}
                          class="text-[10px] font-bold text-emerald-400 hover:text-emerald-300 uppercase tracking-widest"
                        >
                          Copy
                        </button>
                        <button
                          phx-click="toggle_reveal"
                          phx-value-target="agent_token"
                          class="text-[10px] font-bold text-gray-400 hover:text-white uppercase tracking-widest"
                        >
                          {if @show_agent_token, do: "Hide", else: "Reveal"}
                        </button>
                      </div>
                    </div>
                    <code class="block bg-black/40 border border-white/10 rounded-xl px-4 py-2.5 text-xs text-emerald-400 font-mono truncate">
                      <%= cond do %>
                        <% is_nil(@selected_agent.api_token) -> %>
                          Generating...
                        <% @show_agent_token -> %>
                          {@selected_agent.api_token}
                        <% true -> %>
                          {mask_token(@selected_agent.api_token)}
                      <% end %>
                    </code>
                    <p class="text-[10px] text-gray-600 mt-1">
                      Use Copy to send the token to your clipboard without revealing it on screen.
                    </p>
                  </div>

                  <%!-- Option A — Claude Code (terminal or app) --%>
                  <div>
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-[10px] font-black text-blue-400 uppercase tracking-widest">
                        Option A — Claude Code
                      </span>
                      <div class="flex items-center gap-3">
                        <button
                          id={"copy-claude-code-#{@selected_agent.id}"}
                          phx-hook="CopyToClipboard"
                          data-text={claude_code_prompt(@selected_agent)}
                          class="text-[10px] font-bold text-blue-400 hover:text-blue-300 uppercase tracking-widest"
                        >
                          Copy Prompt
                        </button>
                        <button
                          phx-click="toggle_reveal"
                          phx-value-target="option_a"
                          class="text-[10px] font-bold text-gray-400 hover:text-white uppercase tracking-widest"
                        >
                          {if @show_option_a, do: "Hide", else: "Reveal"}
                        </button>
                      </div>
                    </div>
                    <ol class="text-[11px] text-gray-400 space-y-1 list-decimal list-inside mb-2 leading-relaxed">
                      <li>Start a Claude Code instance — terminal or the Claude Code app.</li>
                      <li>Copy this prompt and paste it into the Claude Code window.</li>
                      <li>
                        Your agent will start running. The token is already embedded in the prompt.
                      </li>
                    </ol>
                    <%= if @show_option_a do %>
                      <pre class="bg-black/40 border border-blue-500/20 rounded-xl p-3 text-[9px] sm:text-[10px] text-gray-300 font-mono whitespace-pre-wrap leading-relaxed max-h-40 sm:max-h-48 overflow-y-auto"><%= claude_code_prompt(@selected_agent) %></pre>
                      <p class="text-[10px] text-gray-600 mt-1">
                        Token is pre-filled — use only in a trusted local Claude Code client, not public or shared chats.
                      </p>
                    <% end %>
                  </div>

                  <%!-- Option B — Codex Terminal --%>
                  <div>
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-[10px] font-black text-emerald-400 uppercase tracking-widest">
                        Option B — Codex Terminal
                        <span class="ml-2 text-[9px] font-bold text-gray-500">
                          {KiteAgentHubWeb.CodexPrompts.agent_type_label(@selected_agent)}
                        </span>
                      </span>
                      <div class="flex items-center gap-3">
                        <button
                          id={"copy-codex-#{@selected_agent.id}"}
                          phx-hook="CopyToClipboard"
                          data-text={KiteAgentHubWeb.CodexPrompts.combined_block(@selected_agent)}
                          class="text-[10px] font-bold text-emerald-400 hover:text-emerald-300 uppercase tracking-widest"
                        >
                          Copy Prompt
                        </button>
                        <button
                          phx-click="toggle_reveal"
                          phx-value-target="option_b"
                          class="text-[10px] font-bold text-gray-400 hover:text-white uppercase tracking-widest"
                        >
                          {if @show_option_b, do: "Hide", else: "Reveal"}
                        </button>
                      </div>
                    </div>
                    <ol class="text-[11px] text-gray-400 space-y-1 list-decimal list-inside mb-2 leading-relaxed">
                      <li>Open a blank terminal window.</li>
                      <li>Copy the Codex prompt and paste it into the terminal.</li>
                      <li>
                        When the terminal asks for your token, use Copy on the Agent Token above and paste it in. Codex will start up as your agent.
                      </li>
                    </ol>
                    <%= if @show_option_b do %>
                      <pre class="bg-black/40 border border-emerald-500/20 rounded-xl p-3 text-[9px] sm:text-[10px] text-gray-300 font-mono whitespace-pre-wrap leading-relaxed max-h-40 sm:max-h-48 overflow-y-auto"><%= KiteAgentHubWeb.CodexPrompts.combined_block(@selected_agent) %></pre>
                      <p class="text-[10px] text-gray-500 mt-1 leading-snug">
                        <span class="text-yellow-400">Requires Codex Terminal / Codex CLI.</span>
                        The command asks Terminal for your token privately before Codex starts; do not paste the token into Codex chat.
                        ChatGPT browser, desktop, or mobile chat cannot keep the agent online — they cannot run the long-poll loop locally.
                        If <code class="text-gray-400">codex</code>
                        is not recognized, install or open Codex Terminal and follow its OS-specific setup.
                        <%= if KiteAgentHubWeb.CodexPrompts.can_trade?(@selected_agent) do %>
                          <span class="text-yellow-400">
                            Trade Agent — only Trade Agents can submit trades.
                          </span>
                        <% else %>
                          <span class="text-gray-500">Read-only — cannot submit trades.</span>
                        <% end %>
                      </p>
                    <% end %>
                  </div>

                  <%!-- Agents make mistakes disclaimer --%>
                  <div class="rounded-xl border border-yellow-500/20 bg-yellow-500/[0.04] px-4 py-3">
                    <p class="text-[11px] text-yellow-200/80 leading-relaxed">
                      <span class="font-bold text-yellow-300">Heads up:</span>
                      agents make mistakes. Review their trades and chat output regularly, and start small while you tune their behavior.
                    </p>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- ═══════════════ ATTESTATIONS TAB ═══════════════ --%>
          <%= if @active_tab == :attestations do %>
            <div class="w-full px-4 sm:px-6 lg:px-8 py-8">
              <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest mb-6">
                Kite Chain Attestations
              </h2>
              <%= if @selected_agent do %>
                <div class="rounded-2xl border border-emerald-500/20 bg-gradient-to-r from-emerald-500/[0.04] to-emerald-500/[0.01] backdrop-blur-md overflow-hidden">
                  <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 px-6 py-5 border-b border-emerald-500/10">
                    <div class="flex items-center gap-3 min-w-0">
                      <div class="h-8 w-8 rounded-full bg-emerald-500/[0.18] flex items-center justify-center shrink-0 text-emerald-400 text-base font-black shadow-[0_0_10px_rgba(34,197,94,0.3)]">
                        ✓
                      </div>
                      <div class="min-w-0">
                        <p class="text-[10px] text-emerald-400 uppercase tracking-widest">
                          On-Chain History
                        </p>
                        <p class="text-sm font-black text-white tracking-tight">
                          {@attestation_count}
                          <span class="text-xs font-mono text-gray-500">attested trades</span>
                        </p>
                      </div>
                    </div>
                    <%= if @selected_agent.wallet_address do %>
                      <a
                        href={
                          explorer_address_url(
                            @selected_agent.wallet_address,
                            @selected_agent.chain_id
                          )
                        }
                        target="_blank"
                        rel="noopener noreferrer"
                        class="inline-flex items-center gap-2 px-4 py-2 rounded-xl border border-emerald-500/30 bg-emerald-500/10 hover:bg-emerald-500/20 text-emerald-300 hover:text-emerald-200 text-xs uppercase tracking-widest transition-all whitespace-nowrap"
                      >
                        View on Kitescan →
                      </a>
                    <% end %>
                  </div>

                  <%= if @all_attestations == [] do %>
                    <div class="px-6 py-20 text-center">
                      <p class="text-sm font-bold text-gray-400">No attestations yet</p>
                      <p class="text-xs text-gray-600 mt-2 font-mono">
                        <%= if @selected_agent.status == "active" do %>
                          Trades will appear here once they settle and sign to Kite chain
                        <% else %>
                          Activate this agent to begin writing trade attestations
                        <% end %>
                      </p>
                    </div>
                  <% else %>
                    <div class="divide-y divide-emerald-500/5">
                      <div class="hidden md:grid md:grid-cols-12 gap-4 px-6 py-3 text-[10px] text-gray-500 uppercase tracking-widest">
                        <div class="col-span-1">Action</div>
                        <div class="col-span-3">Market</div>
                        <div class="col-span-3">Tx Hash</div>
                        <div class="col-span-2">Time</div>
                        <div class="col-span-2">PNL</div>
                        <div class="col-span-1 text-right">Status</div>
                      </div>
                      <%= for att <- @all_attestations do %>
                        <div class="grid grid-cols-2 md:grid-cols-12 gap-3 md:gap-4 px-6 py-4 hover:bg-emerald-500/[0.03] transition-colors items-center">
                          <div class="col-span-1 md:col-span-1">
                            <span class={[
                              "inline-flex items-center justify-center px-2 py-1 rounded-lg border text-[10px] uppercase tracking-widest",
                              att.action == "buy" &&
                                "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e]",
                              att.action == "sell" &&
                                "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]",
                              att.action not in ["buy", "sell"] &&
                                "bg-gray-500/10 border-gray-500/20 text-gray-400"
                            ]}>
                              {att.action || "unkn"}
                            </span>
                          </div>
                          <div class="col-span-1 md:col-span-3 min-w-0">
                            <p
                              class="text-sm font-black text-white tracking-tight truncate"
                              title={att.market}
                            >
                              {truncate_market(att.market)}
                            </p>
                            <p class="text-[10px] text-gray-600 font-mono md:hidden">
                              {att.contracts}x @ ${att.fill_price}
                            </p>
                          </div>
                          <div class="col-span-2 md:col-span-3 min-w-0">
                            <a
                              href={
                                explorer_tx_url(att.attestation_tx_hash, @selected_agent.chain_id)
                              }
                              target="_blank"
                              rel="noopener noreferrer"
                              class="inline-flex items-center gap-1 text-[11px] font-mono text-emerald-400 hover:text-emerald-300 transition-colors"
                              title={att.attestation_tx_hash}
                            >
                              {String.slice(att.attestation_tx_hash, 0, 10)}…{String.slice(
                                att.attestation_tx_hash,
                                -6,
                                6
                              )}
                              <span class="text-emerald-500/60">↗</span>
                            </a>
                          </div>
                          <div class="col-span-1 md:col-span-2">
                            <p
                              id={"attestation-time-#{att.id}"}
                              phx-hook="LocalTime"
                              data-iso={DateTime.to_iso8601(att.updated_at)}
                              data-format="datetime"
                              class="text-[11px] text-gray-400 font-mono"
                            >
                              {Calendar.strftime(att.updated_at, "%b %d %H:%M")}
                            </p>
                          </div>
                          <div class="col-span-1 md:col-span-2">
                            <%= if att.display_pnl do %>
                              <p class={[
                                "text-sm font-bold font-mono",
                                Decimal.gt?(att.display_pnl, 0) && "text-[#22c55e]",
                                Decimal.lt?(att.display_pnl, 0) && "text-[#ef4444]",
                                Decimal.eq?(att.display_pnl, 0) && "text-gray-500"
                              ]}>
                                {if Decimal.gt?(att.display_pnl, 0), do: "+"}${format_compact_pnl(
                                  att.display_pnl
                                )}
                              </p>
                            <% else %>
                              <p class="text-xs text-gray-600 font-mono">—</p>
                            <% end %>
                          </div>
                          <div class="col-span-1 md:col-span-1 md:text-right">
                            <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full border border-emerald-500/20 bg-emerald-500/10 text-emerald-400 text-[10px] uppercase tracking-widest">
                              ✓ {att.status}
                            </span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-20 text-center">
                  <p class="text-sm font-bold text-gray-400">Select an agent to view attestations</p>
                  <p class="text-xs text-gray-600 mt-2 font-mono">
                    Each settled trade writes a signed receipt to the Kite chain
                  </p>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- ═══════════════ KITE WALLET TAB ═══════════════ --%>
          <%= if @active_tab == :wallet do %>
            <div class="w-full px-4 sm:px-6 lg:px-8 py-8">
              <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest mb-6">
                Kite Wallet
              </h2>
              <%= if @selected_agent do %>
                <div class="space-y-4">
                  <%!-- Wallet address --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-2 font-bold">
                      Wallet Address
                    </p>
                    <p class="font-mono text-sm text-white break-all">
                      {@selected_agent.wallet_address || "—"}
                    </p>
                    <%= if @selected_agent.wallet_address do %>
                      <a
                        href={
                          explorer_address_url(
                            @selected_agent.wallet_address,
                            @selected_agent.chain_id
                          )
                        }
                        target="_blank"
                        class="text-xs text-[#22c55e] hover:underline mt-2 inline-block font-mono"
                      >
                        View on Kitescan ↗
                      </a>
                    <% end %>
                  </div>
                  <%!-- Vault address --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-2 font-bold">
                      Vault Address
                    </p>
                    <p class="font-mono text-sm text-white break-all">
                      {if @selected_agent.vault_address,
                        do: @selected_agent.vault_address,
                        else: "Not set — paste vault address above"}
                    </p>
                    <%= if @selected_agent.vault_address do %>
                      <a
                        href={
                          explorer_address_url(
                            @selected_agent.vault_address,
                            @selected_agent.chain_id
                          )
                        }
                        target="_blank"
                        class="text-xs text-[#22c55e] hover:underline mt-2 inline-block font-mono"
                      >
                        View vault on Kitescan ↗
                      </a>
                    <% end %>
                  </div>
                  <%!-- Balance --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-2 font-bold">
                      KITE Balance
                    </p>
                    <p class="text-3xl font-black text-white">
                      {if @wallet_balance_eth, do: "#{@wallet_balance_eth} KITE", else: "—"}
                    </p>
                  </div>
                  <%!-- Token balances (ERC-20: USDT, etc.) --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-4 font-bold">
                      Token Balances
                    </p>
                    <%= cond do %>
                      <% @wallet_tokens == :loading -> %>
                        <div class="flex items-center gap-3 text-gray-500 py-4">
                          <div class="w-4 h-4 border-2 border-white/20 border-t-white/60 rounded-full animate-spin">
                          </div>
                          <span class="text-xs">Loading token balances...</span>
                        </div>
                      <% is_list(@wallet_tokens) && @wallet_tokens != [] -> %>
                        <div class="space-y-3">
                          <%= for token <- @wallet_tokens do %>
                            <div class="flex items-center justify-between py-2 border-b border-white/5 last:border-0">
                              <div class="min-w-0">
                                <p class="text-sm font-bold text-white">{token.symbol}</p>
                                <p class="text-[10px] text-gray-500 truncate">{token.token}</p>
                              </div>
                              <p class="text-sm font-mono text-white tabular-nums">
                                {format_token_balance(token.balance, token.decimals)}
                              </p>
                            </div>
                          <% end %>
                        </div>
                      <% true -> %>
                        <p class="text-xs text-gray-500 py-2">
                          No ERC-20 tokens held by this wallet.
                        </p>
                    <% end %>
                  </div>
                  <%!-- Chain info --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 flex items-center justify-between">
                    <div>
                      <p class="text-xs text-gray-500 uppercase tracking-widest mb-1 font-bold">
                        Network
                      </p>
                      <p class="text-sm text-white font-mono">
                        Kite {KiteAgentHub.Kite.ChainId.label()}
                      </p>
                    </div>
                    <div class="text-right">
                      <p class="text-xs text-gray-500 uppercase tracking-widest mb-1 font-bold">
                        Block
                      </p>
                      <p class="text-sm text-white font-mono">{@block_number || "—"}</p>
                    </div>
                  </div>
                  <%!-- On-chain transaction history --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-4 font-bold">
                      Recent On-Chain Transactions
                    </p>
                    <%= cond do %>
                      <% @wallet_txs == :loading -> %>
                        <div class="flex items-center gap-3 text-gray-500 py-4">
                          <div class="w-4 h-4 border-2 border-white/20 border-t-white/60 rounded-full animate-spin">
                          </div>
                          <span class="text-xs">Loading transactions from Kitescan...</span>
                        </div>
                      <% is_list(@wallet_txs) && @wallet_txs != [] -> %>
                        <div class="space-y-3">
                          <%= for tx <- @wallet_txs do %>
                            <div class="flex items-center justify-between py-2 border-b border-white/5 last:border-0">
                              <div class="flex items-center gap-3 min-w-0">
                                <div class={"w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold #{if tx.from && String.downcase(tx.from) == String.downcase(@selected_agent.wallet_address || ""), do: "bg-red-500/20 text-red-400", else: "bg-green-500/20 text-green-400"}"}>
                                  {if tx.from &&
                                        String.downcase(tx.from) ==
                                          String.downcase(@selected_agent.wallet_address || ""),
                                      do: "↑",
                                      else: "↓"}
                                </div>
                                <div class="min-w-0">
                                  <a
                                    href={explorer_tx_url(tx.hash, @selected_agent.chain_id)}
                                    target="_blank"
                                    class="text-xs font-mono text-[#22c55e] hover:underline truncate block max-w-[200px]"
                                  >
                                    {String.slice(tx.hash || "", 0..13)}...
                                  </a>
                                  <p class="text-[10px] text-gray-600 font-mono">
                                    {if tx.timestamp,
                                      do: String.slice(to_string(tx.timestamp), 0..18),
                                      else: "—"}
                                  </p>
                                </div>
                              </div>
                              <div class="text-right">
                                <p class="text-xs font-mono text-white">{tx.value_eth} KITE</p>
                                <p class="text-[10px] text-gray-600">{tx.status || "confirmed"}</p>
                              </div>
                            </div>
                          <% end %>
                        </div>
                      <% true -> %>
                        <p class="text-xs text-gray-600 py-4">
                          No on-chain transactions yet. Fund your wallet at faucet.gokite.ai to see activity here.
                        </p>
                    <% end %>
                  </div>
                </div>
              <% else %>
                <p class="text-gray-500 text-sm">No agent selected.</p>
              <% end %>
            </div>
          <% end %>

          <%!-- ═══════════════ EDGESCORER TAB ═══════════════ --%>
          <%= if @active_tab == :edge_scorer do %>
            <div class="w-full px-4 sm:px-6 lg:px-8 py-8 space-y-6">
              <div class="flex items-center justify-between">
                <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">
                  EdgeScorer — Portfolio Analysis
                </h2>
                <button
                  phx-click="switch_tab"
                  phx-value-tab="edge_scorer"
                  class="text-xs text-gray-500 hover:text-white transition-colors font-mono uppercase tracking-widest"
                >
                  ↻ Refresh
                </button>
              </div>

              <%= if @edge_scores_loading do %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                  <p class="text-gray-500 text-sm animate-pulse">Scoring positions...</p>
                </div>
              <% else %>
                <%= if @portfolio_scores do %>
                  <% all_scores =
                    (@portfolio_scores.alpaca_scores || []) ++ (@portfolio_scores.kalshi_scores || []) %>

                  <%!-- Position Scores --%>
                  <%= if all_scores != [] do %>
                    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
                      <%= for score <- all_scores do %>
                        <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 hover:border-white/20 transition-all">
                          <div class="flex items-center justify-between mb-3">
                            <div>
                              <span class="text-sm font-black text-white tracking-tight">
                                {score[:ticker] || score[:title]}
                              </span>
                              <span class={[
                                "ml-2 text-[10px] font-bold px-2 py-0.5 rounded border uppercase",
                                score.platform == :alpaca &&
                                  "text-blue-400 border-blue-500/20 bg-blue-500/10",
                                score.platform == :kalshi &&
                                  "text-purple-400 border-purple-500/20 bg-purple-500/10"
                              ]}>
                                {score.platform}
                              </span>
                            </div>
                            <span class={[
                              "text-[10px] uppercase tracking-widest px-2 py-1 rounded-full border",
                              score.recommendation == :strong_hold &&
                                "text-[#22c55e] border-[#22c55e]/30 bg-[#22c55e]/10",
                              score.recommendation == :hold &&
                                "text-[#f59e0b] border-[#f59e0b]/30 bg-[#f59e0b]/10",
                              score.recommendation == :watch &&
                                "text-orange-400 border-orange-500/30 bg-orange-500/10",
                              score.recommendation == :exit &&
                                "text-[#ef4444] border-[#ef4444]/30 bg-[#ef4444]/10"
                            ]}>
                              {String.replace(Atom.to_string(score.recommendation), "_", " ")}
                            </span>
                          </div>
                          <%!-- Score bar --%>
                          <div class="mb-3">
                            <div class="flex items-center justify-between mb-1">
                              <span class="text-[10px] text-gray-500 font-mono uppercase tracking-widest">
                                Edge
                              </span>
                              <span class="text-xl font-black text-white">{score.score}</span>
                            </div>
                            <div class="h-1.5 rounded-full bg-white/10 overflow-hidden">
                              <div
                                class={[
                                  "h-full rounded-full",
                                  score.score >= 75 && "bg-[#22c55e]",
                                  score.score >= 60 && score.score < 75 && "bg-[#f59e0b]",
                                  score.score >= 40 && score.score < 60 && "bg-orange-500",
                                  score.score < 40 && "bg-[#ef4444]"
                                ]}
                                style={"width: #{score.score}%"}
                              >
                              </div>
                            </div>
                          </div>
                          <%!-- Position data --%>
                          <div class="space-y-1.5 text-xs font-mono">
                            <div class="flex justify-between text-gray-400">
                              <span>Side</span>
                              <span class="text-white">{score.side}</span>
                            </div>
                            <div class="flex justify-between text-gray-400">
                              <span>P&L</span>
                              <span class={[
                                score.pnl_pct >= 0 && "text-[#22c55e]",
                                score.pnl_pct < 0 && "text-[#ef4444]"
                              ]}>
                                {if score.pnl_pct >= 0, do: "+", else: ""}{score.pnl_pct}%
                              </span>
                            </div>
                          </div>
                          <%!-- Breakdown --%>
                          <div class="mt-3 pt-3 border-t border-white/10 grid grid-cols-2 gap-1.5 text-[10px] font-mono text-gray-500">
                            <span>
                              Entry:
                              <span class="text-gray-300">{score.breakdown.entry_quality}/30</span>
                            </span>
                            <span>
                              Momentum:
                              <span class="text-gray-300">{score.breakdown.momentum}/25</span>
                            </span>
                            <span>
                              R:R: <span class="text-gray-300">{score.breakdown.risk_reward}/25</span>
                            </span>
                            <span>
                              Liquidity:
                              <span class="text-gray-300">{score.breakdown.liquidity}/20</span>
                            </span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% end %>

                  <%!-- Suggestions --%>
                  <%= if @portfolio_scores.suggestions != [] do %>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-hidden">
                      <div class="px-6 py-4 border-b border-white/10">
                        <h3 class="text-xs font-black text-white uppercase tracking-widest">
                          Agent Suggestions
                        </h3>
                      </div>
                      <div class="divide-y divide-white/5">
                        <%= for sug <- @portfolio_scores.suggestions do %>
                          <div class="px-6 py-3 flex items-center justify-between">
                            <div class="flex items-center gap-3">
                              <span class={[
                                "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                sug.action == :exit && "text-red-400 border-red-500/20 bg-red-500/10",
                                sug.action == :hold &&
                                  "text-emerald-400 border-emerald-500/20 bg-emerald-500/10"
                              ]}>
                                {sug.action}
                              </span>
                              <span class="text-xs text-white font-bold">{sug.ticker}</span>
                              <span class="text-[10px] text-gray-500">{sug.platform}</span>
                            </div>
                            <span class="text-xs text-gray-400">{sug.reason}</span>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>

                  <%= if all_scores == [] do %>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                      <p class="text-gray-500 text-sm">
                        No open positions to score. Open trades on the Alpaca or Kalshi tabs first.
                      </p>
                    </div>
                  <% end %>
                <% else %>
                  <div class="rounded-2xl border border-yellow-500/20 bg-yellow-500/5 p-10 text-center space-y-3">
                    <p class="text-yellow-400 text-sm font-bold">Could not load portfolio data</p>
                    <p class="text-gray-500 text-xs">
                      Check API keys in Settings, then try refreshing.
                    </p>
                    <button
                      phx-click="switch_tab"
                      phx-value-tab="edge_scorer"
                      class="inline-flex items-center gap-2 px-4 py-2 rounded-xl border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] text-white text-xs uppercase tracking-widest transition-all"
                    >
                      ↻ Retry
                    </button>
                  </div>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <%!-- Alpaca Tab --%>
          <%= if @active_tab == :alpaca do %>
            <div class="px-4 sm:px-6 lg:px-8 py-6 space-y-6">
              <%= case @alpaca_data do %>
                <% :loading -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm animate-pulse">Loading Alpaca account...</p>
                  </div>
                <% :not_configured -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm mb-3">Alpaca API keys not configured.</p>
                    <.link navigate={~p"/api-keys"} class="text-xs font-bold text-white underline">
                      Add keys in Settings →
                    </.link>
                  </div>
                <% :unauthorized -> %>
                  <div class="rounded-2xl border border-red-500/20 bg-red-500/5 p-6 text-center">
                    <p class="text-red-400 text-sm">
                      Alpaca credentials invalid — check your API key in Settings.
                    </p>
                  </div>
                <% :error -> %>
                  <div class="rounded-2xl border border-yellow-500/20 bg-yellow-500/5 p-6 text-center">
                    <p class="text-yellow-400 text-sm">Could not reach Alpaca API. Try refreshing.</p>
                  </div>
                <% nil -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm">
                      Click the Alpaca tab to load your paper account.
                    </p>
                  </div>
                <% data -> %>
                  <%!-- ═══════════ ALPACA HERO ═══════════
                       Hero card mirrors the Portfolio tab template
                       (Mico 9931 hedge-fund redesign): radial sheen,
                       7xl Portfolio Value, solid Today pill. Brand
                       palette = Alpaca yellow (#f59e0b).
                       CyberSec 13757: sheen direction is keyed off
                       SERVER-rendered `data-positive` / `data-negative`
                       attrs — JS never sign-detects a formatted
                       currency string. --%>
                  <% pv_value = data.account.portfolio_value || 0.0 %>
                  <% has_day_delta? =
                    is_number(data.account.last_equity) and
                      is_number(data.account.equity) and
                      data.account.last_equity > 0 %>
                  <% day_change_usd =
                    if has_day_delta?,
                      do: data.account.equity - data.account.last_equity,
                      else: 0.0 %>
                  <% day_change_pct =
                    if has_day_delta?,
                      do: day_change_usd / data.account.last_equity * 100,
                      else: 0.0 %>
                  <% day_up? = day_change_usd >= 0 %>
                  <div
                    class="relative overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-white/[0.04] via-white/[0.02] to-transparent p-6 sm:p-10 backdrop-blur-md"
                    data-positive={if has_day_delta? and day_up?, do: "true", else: "false"}
                    data-negative={if has_day_delta? and not day_up?, do: "true", else: "false"}
                  >
                    <div
                      class="pointer-events-none absolute -top-32 -right-32 w-96 h-96 rounded-full opacity-25 blur-3xl"
                      style={
                        cond do
                          has_day_delta? and not day_up? ->
                            "background: radial-gradient(circle, rgba(239,68,68,0.40), transparent 65%);"

                          true ->
                            "background: radial-gradient(circle, rgba(245,158,11,0.45), transparent 65%);"
                        end
                      }
                    />
                    <div class="relative flex flex-col gap-6">
                      <div class="flex items-start justify-between gap-4 flex-wrap">
                        <p class="text-[10px] sm:text-xs text-amber-400/80 uppercase tracking-[0.3em]">
                          Alpaca · Portfolio Value
                        </p>
                        <span class="inline-flex items-center gap-2 px-3 py-1 rounded-full border border-amber-500/30 bg-amber-500/[0.08] text-[10px] font-mono text-amber-300">
                          <span class="w-1.5 h-1.5 rounded-full bg-amber-400 shadow-[0_0_8px_#f59e0b] animate-pulse">
                          </span>
                          paper · live
                        </span>
                      </div>
                      <h2 class="text-5xl sm:text-6xl lg:text-7xl tabular-nums tracking-tight text-white leading-none flex items-baseline">
                        <span class="text-amber-400/60 font-light">$</span><span
                          id="alpaca-portfolio-value"
                          phx-hook="CountUp"
                          data-target={pv_value}
                          data-decimals="2"
                        >{:erlang.float_to_binary(pv_value, decimals: 2)}</span>
                      </h2>
                      <%= if has_day_delta? do %>
                        <%!-- Solid Today pill — opaque colored bg so it pops
                             off the sheen. Raw signed values exposed on
                             `data-value-usd` / `data-value-pct` for any future
                             hook (CyberSec 13757: do not parse textContent). --%>
                        <div class="flex flex-wrap items-center gap-3">
                          <div
                            class={[
                              "inline-flex items-center gap-3 px-4 py-2 rounded-xl font-mono text-base sm:text-lg tabular-nums shadow-lg",
                              day_up? && "bg-emerald-600 text-white",
                              not day_up? && "bg-red-600 text-white"
                            ]}
                            data-value-usd={:erlang.float_to_binary(day_change_usd, decimals: 2)}
                            data-value-pct={:erlang.float_to_binary(day_change_pct, decimals: 2)}
                          >
                            <span class="text-[9px] uppercase tracking-[0.2em] text-white/70 border-r border-white/30 pr-3">
                              Today
                            </span>
                            <span>{if day_up?, do: "▲", else: "▼"}</span>
                            <span>${:erlang.float_to_binary(abs(day_change_usd), decimals: 2)}</span>
                            <span class="text-xs text-white/80">
                              ({:erlang.float_to_binary(abs(day_change_pct), decimals: 2)}%)
                            </span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- ═══════════ 4-UP KPI STRIP ═══════════
                       Equity · Cash · Buying Power · Reg-T BP. CountUp
                       animates each on mount and on every LV patch via
                       the existing app.js hook (PR #404/#410). Reg-T BP
                       was promoted out of the margin strip — it's the
                       fourth "money you can actually deploy" number. --%>
                  <% alpaca_kpis = [
                    %{
                      key: "equity",
                      label: "Equity",
                      value: data.account.equity || 0.0,
                      text_cls: "text-emerald-300",
                      border_cls: "border-emerald-500/20",
                      glow_cls: "from-emerald-500/[0.06]"
                    },
                    %{
                      key: "cash",
                      label: "Cash",
                      value: data.account.cash || 0.0,
                      text_cls: "text-amber-200",
                      border_cls: "border-amber-500/20",
                      glow_cls: "from-amber-500/[0.06]"
                    },
                    %{
                      key: "buying-power",
                      label: "Buying Power",
                      value: data.account.buying_power || 0.0,
                      text_cls: "text-sky-300",
                      border_cls: "border-sky-500/20",
                      glow_cls: "from-sky-500/[0.06]"
                    },
                    %{
                      key: "regt-bp",
                      label: "Reg-T BP",
                      value: data.account.regt_buying_power || 0.0,
                      text_cls: "text-fuchsia-300",
                      border_cls: "border-fuchsia-500/20",
                      glow_cls: "from-fuchsia-500/[0.06]"
                    }
                  ] %>
                  <div
                    id="alpaca-kpi-strip"
                    phx-hook="FadeInStagger"
                    class="grid grid-cols-2 lg:grid-cols-4 gap-3"
                  >
                    <%= for kpi <- alpaca_kpis do %>
                      <div class={[
                        "relative overflow-hidden rounded-2xl border bg-gradient-to-br to-transparent p-4",
                        kpi.border_cls,
                        kpi.glow_cls
                      ]}>
                        <p class="text-[9px] sm:text-[10px] text-gray-500 uppercase tracking-widest mb-2">
                          {kpi.label}
                        </p>
                        <p class={["text-xl sm:text-2xl tabular-nums", kpi.text_cls]}>
                          <span class="opacity-60 font-light mr-0.5">$</span><span
                            id={"alpaca-kpi-#{kpi.key}"}
                            phx-hook="CountUp"
                            data-target={kpi.value}
                            data-decimals="2"
                          >{:erlang.float_to_binary(kpi.value, decimals: 2)}</span>
                        </p>
                      </div>
                    <% end %>
                  </div>

                  <%!-- ═══════════ MARGIN & SHORTABLE ═══════════
                       Reg-T BP moved up to the KPI strip; what remains
                       here is the secondary "how much can I lever / can
                       I short" context. Bold-on-uppercase doubles
                       removed per Mico 10094 — uppercase alone reads
                       cleaner. --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-5">
                    <p class="text-[10px] text-gray-500 uppercase tracking-widest mb-3">
                      Margin Details
                    </p>
                    <div class="grid grid-cols-2 gap-4">
                      <div>
                        <p class="text-[9px] text-gray-600 uppercase tracking-widest mb-1">
                          Day-Trade BP
                        </p>
                        <p class="text-base text-amber-100/90 tabular-nums font-medium">
                          ${format_money(data.account.daytrading_buying_power)}
                        </p>
                      </div>
                      <div>
                        <p class="text-[9px] text-gray-600 uppercase tracking-widest mb-1">
                          Non-Marginable BP
                        </p>
                        <p class="text-base text-amber-100/90 tabular-nums font-medium">
                          ${format_money(data.account.non_marginable_buying_power)}
                        </p>
                      </div>
                    </div>
                  </div>

                  <%!-- Equity Chart --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <div class="flex items-center justify-between mb-4 flex-wrap gap-2">
                      <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                        Portfolio Equity ({@alpaca_period})
                      </p>
                      <%= if length(@alpaca_history) > 1 do %>
                        <% last_val = List.last(@alpaca_history).v %>
                        <%!-- Alpaca's portfolio_history endpoint returns
                             `base_value` — the exact baseline Alpaca uses for
                             the requested period (matches the % shown in the
                             Alpaca app). Prefer it. Fall back to the first
                             chart point if the field is missing (e.g. on
                             very old data or a custom range). --%>
                        <% first_val =
                          cond do
                            is_number(@alpaca_history_base_value) and
                                @alpaca_history_base_value > 0 ->
                              @alpaca_history_base_value

                            true ->
                              List.first(@alpaca_history).v
                          end %>
                        <% pct_change =
                          if first_val > 0,
                            do: Float.round((last_val - first_val) / first_val * 100, 2),
                            else: 0.0 %>
                        <span class={"text-xs font-mono font-bold #{if pct_change >= 0, do: "text-[#22c55e]", else: "text-red-400"}"}>
                          {if pct_change >= 0, do: "+", else: ""}{pct_change}%
                        </span>
                      <% end %>
                    </div>

                    <%!-- Range buttons --%>
                    <div class="flex flex-wrap gap-1 mb-4">
                      <%= for range <- ~w(1D 3D 1W 1M 3M 6M 1Y 2Y 3Y All) do %>
                        <button
                          phx-click="alpaca_period"
                          phx-value-period={range}
                          class={[
                            "px-2.5 py-1 rounded-lg text-[10px] uppercase tracking-widest transition-all border",
                            @alpaca_period == range && "bg-white text-black border-white",
                            @alpaca_period != range &&
                              "bg-white/[0.02] text-gray-500 border-white/10 hover:text-white hover:border-white/20"
                          ]}
                        >
                          {range}
                        </button>
                      <% end %>
                    </div>

                    <%!-- Same trading-chart treatment as the Forex instrument
                         view (Mico 13772 — modernize alongside Forex). The
                         range tab strip above is unchanged; only the SVG
                         body is upgraded. CrosshairChart hook reads
                         `data-points` from the server-rendered JSON, same
                         CyberSec 13769 rules. --%>
                    <% alpaca_chart = alpaca_equity_chart_data(@alpaca_history, 640, 200) %>
                    <%= case alpaca_chart do %>
                      <% :empty -> %>
                        <p class="text-center text-gray-600 text-xs py-10">
                          No equity history for this range.
                        </p>
                      <% c -> %>
                        <% stroke = if c.delta >= 0, do: "#22c55e", else: "#ef4444" %>
                        <div class="flex items-baseline justify-between mb-2 flex-wrap gap-2">
                          <p class="text-2xl font-mono tabular-nums text-white">
                            ${:erlang.float_to_binary(c.last, decimals: 2)}
                          </p>
                          <span class={[
                            "text-xs font-mono tabular-nums px-2 py-0.5 rounded",
                            c.delta >= 0 && "bg-emerald-500/15 text-emerald-300",
                            c.delta < 0 && "bg-red-500/15 text-red-300"
                          ]}>
                            {if c.delta >= 0, do: "+", else: ""}${:erlang.float_to_binary(c.delta,
                              decimals: 2
                            )} ({:erlang.float_to_binary(c.delta_pct, decimals: 2)}%)
                          </span>
                        </div>
                        <div
                          id="alpaca-equity-chart"
                          phx-hook="CrosshairChart"
                          class="relative"
                          data-points={c.crosshair_data}
                        >
                          <svg
                            viewBox="0 0 700 220"
                            preserveAspectRatio="none"
                            class="w-full h-56 select-none cursor-crosshair"
                          >
                            <defs>
                              <linearGradient
                                id="alpaca-equity-fill"
                                x1="0"
                                y1="0"
                                x2="0"
                                y2="1"
                              >
                                <stop offset="0%" stop-color={stroke} stop-opacity="0.42" />
                                <stop offset="60%" stop-color={stroke} stop-opacity="0.12" />
                                <stop offset="100%" stop-color={stroke} stop-opacity="0.0" />
                              </linearGradient>
                              <filter
                                id="alpaca-equity-glow"
                                x="-10%"
                                y="-30%"
                                width="120%"
                                height="160%"
                              >
                                <feGaussianBlur stdDeviation="2.2" result="blur" />
                                <feMerge>
                                  <feMergeNode in="blur" />
                                  <feMergeNode in="SourceGraphic" />
                                </feMerge>
                              </filter>
                            </defs>
                            <g transform="translate(0,10)">
                              <%!-- Subtle chart canvas tint — gives the plot
                                   area its own surface vs the card background
                                   (Phorari 13809: lighter chart bg). --%>
                              <rect
                                x="0"
                                y="0"
                                width="640"
                                height="200"
                                fill="white"
                                fill-opacity="0.03"
                              />
                              <%= for {tick, idx} <- Enum.with_index(c.y_ticks) do %>
                                <line
                                  x1="0"
                                  y1={tick.y}
                                  x2="640"
                                  y2={tick.y}
                                  stroke="white"
                                  stroke-opacity={if idx == 2, do: "0.12", else: "0.05"}
                                  stroke-dasharray={if idx == 2, do: "4,4", else: ""}
                                />
                                <text
                                  x="648"
                                  y={tick.y + 3}
                                  fill="rgba(156,163,175,0.7)"
                                  font-size="9"
                                  font-family="ui-monospace, monospace"
                                  text-anchor="start"
                                >
                                  ${tick.label}
                                </text>
                              <% end %>
                              <line
                                x1="640"
                                y1="0"
                                x2="640"
                                y2="200"
                                stroke="white"
                                stroke-opacity="0.10"
                              />
                              <path d={c.area_d} fill="url(#alpaca-equity-fill)" />
                              <path
                                d={c.path_d}
                                fill="none"
                                stroke={stroke}
                                stroke-width="2.25"
                                stroke-linejoin="round"
                                stroke-linecap="round"
                                vector-effect="non-scaling-stroke"
                                filter="url(#alpaca-equity-glow)"
                              />
                              <line
                                data-crosshair-x
                                x1="0"
                                y1="0"
                                x2="0"
                                y2="200"
                                stroke="white"
                                stroke-opacity="0.45"
                                stroke-width="0.5"
                                stroke-dasharray="2,3"
                                class="hidden"
                              />
                              <circle
                                data-crosshair-dot
                                cx="0"
                                cy="0"
                                r="4.5"
                                fill={stroke}
                                stroke="white"
                                stroke-width="1.5"
                                class="hidden"
                              />
                            </g>
                          </svg>
                          <div
                            data-crosshair-tooltip
                            class="hidden absolute pointer-events-none px-3 py-2 rounded-lg bg-gray-900/95 border border-white/15 text-xs font-mono tabular-nums shadow-xl text-white"
                            style="z-index: 5;"
                          >
                            <span data-crosshair-time class="text-gray-300 mr-2"></span>
                            <span data-crosshair-price class="text-white font-semibold"></span>
                          </div>
                        </div>
                        <div class="flex justify-between mt-1 text-[10px] text-gray-600 font-mono tabular-nums pr-[60px]">
                          <span>{Enum.at(c.x_ticks, 0).label}</span>
                          <span>{Enum.at(c.x_ticks, 1).label}</span>
                          <span>{Enum.at(c.x_ticks, 2).label}</span>
                        </div>
                        <div class="flex items-center justify-between mt-3 text-[10px] text-gray-500 font-mono flex-wrap gap-2">
                          <span class="inline-flex items-center gap-1.5">
                            <span class={[
                              "inline-block w-3 h-[2px] rounded",
                              c.delta >= 0 && "bg-emerald-400",
                              c.delta < 0 && "bg-red-400"
                            ]}>
                            </span>
                            Equity
                          </span>
                          <span>
                            Hi ${:erlang.float_to_binary(c.max, decimals: 2)} · Lo ${:erlang.float_to_binary(
                              c.min,
                              decimals: 2
                            )}
                          </span>
                        </div>
                    <% end %>
                  </div>

                  <%!-- Positions --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                    <div class="px-6 py-4 border-b border-white/10 flex items-center justify-between gap-3 flex-wrap">
                      <div class="flex items-center gap-3">
                        <h3 class="text-xs font-black text-white uppercase tracking-widest">
                          Open Positions
                        </h3>

                        <%!-- Live tick status pill — only meaningful when toggle is on --%>
                        <%= if @alpaca_live_tick_enabled do %>
                          <% {dot_color, label} =
                            case @alpaca_live_tick_status do
                              :live -> {"bg-emerald-500", "LIVE"}
                              :connecting -> {"bg-yellow-500", "CONNECTING"}
                              :no_symbols -> {"bg-gray-500", "NO POSITIONS"}
                              :error -> {"bg-red-500", "ERROR"}
                              _ -> {"bg-gray-500", "OFF"}
                            end %>
                          <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full border border-white/15 bg-white/[0.05] text-[10px] uppercase tracking-widest text-white">
                            <span class={["w-1.5 h-1.5 rounded-full", dot_color, "animate-pulse"]}>
                            </span>
                            {label}
                          </span>
                        <% end %>
                      </div>

                      <%!-- Toggle button. When ON, the LiveView subscribes to the
                           AlpacaStream :stocks feed for every symbol in this table
                           and overlays each row's Current price with the latest
                           trade tick. Polling continues at 30s as a fallback. --%>
                      <button
                        phx-click="alpaca_live_tick_toggle"
                        class={[
                          "px-3 py-1.5 rounded-lg border text-[10px] uppercase tracking-widest transition-colors",
                          if(@alpaca_live_tick_enabled,
                            do: "bg-emerald-600 hover:bg-emerald-500 border-emerald-700 text-white",
                            else:
                              "bg-white/[0.05] hover:bg-white/[0.1] border-white/20 text-gray-300 hover:text-white"
                          )
                        ]}
                      >
                        {if @alpaca_live_tick_enabled, do: "Live ticks: ON", else: "Live ticks: OFF"}
                      </button>
                    </div>
                    <%= if data.positions == [] do %>
                      <p class="px-6 py-8 text-center text-sm text-gray-600">No open positions.</p>
                    <% else %>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ["Symbol", "Side", "Qty", "Avg Entry", "Current", "P&L"] do %>
                              <th class="px-2 py-2 sm:px-4 sm:py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                                {h}
                              </th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for p <- data.positions do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-2 py-2 sm:px-4 sm:py-3 font-black text-white">
                                {p.symbol}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 text-gray-400">{p.side}</td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums text-gray-300">
                                {p.qty}
                                <%!-- Surface qty locked in open orders.
                                     Catches HAL-style stuck-order cases
                                     where the position count looks fine
                                     but a sell is hanging. --%>
                                <span
                                  :if={(Map.get(p, :held_for_orders) || 0) > 0}
                                  class="ml-1 inline-flex items-center px-1.5 py-0.5 rounded text-[9px] uppercase tracking-widest border border-yellow-500/30 bg-yellow-500/10 text-yellow-400"
                                  title="Held for resting orders — agent has open buy/sell against this position"
                                >
                                  {format_held(p.held_for_orders)} held
                                </span>
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-400">
                                ${:erlang.float_to_binary(p.avg_entry || 0.0, decimals: 2)}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-300">
                                <% live_price = Map.get(@alpaca_live_tick_prices, p.symbol)
                                display_price = live_price || p.current_price || 0.0 %>
                                <span class={[
                                  if(live_price, do: "text-emerald-300", else: "text-gray-300")
                                ]}>
                                  ${:erlang.float_to_binary(display_price * 1.0, decimals: 2)}
                                </span>
                                <%= if live_price do %>
                                  <span
                                    title="Live tick from Alpaca stream"
                                    class="ml-1 inline-block w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"
                                  >
                                  </span>
                                <% end %>
                              </td>
                              <td class={"px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono font-bold #{if (p.unrealized_pl || 0) >= 0, do: "text-emerald-400", else: "text-red-400"}"}>
                                {if (p.unrealized_pl || 0) >= 0, do: "+", else: ""}${:erlang.float_to_binary(
                                  abs(p.unrealized_pl || 0.0),
                                  decimals: 2
                                )}
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    <% end %>
                  </div>

                  <%!-- Recent Orders --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                    <div class="px-6 py-4 border-b border-white/10 flex items-center justify-between">
                      <h3 class="text-xs font-black text-white uppercase tracking-widest">
                        Recent Filled Orders
                      </h3>
                      <span class="text-[10px] text-gray-600 uppercase tracking-widest">
                        via Alpaca Paper
                      </span>
                    </div>
                    <%= if data.orders == [] do %>
                      <p class="px-6 py-8 text-center text-sm text-gray-600">No filled orders yet.</p>
                    <% else %>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ["Symbol", "Side", "Qty", "Fill Price", "Time"] do %>
                              <th class="px-2 py-2 sm:px-4 sm:py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                                {h}
                              </th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for o <- data.orders do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-2 py-2 sm:px-4 sm:py-3 font-black text-white">
                                {o.symbol}
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  o.side == "buy" &&
                                    "text-emerald-400 border-emerald-500/20 bg-emerald-500/10",
                                  o.side == "sell" && "text-red-400 border-red-500/20 bg-red-500/10"
                                ]}>
                                  {o.side}
                                </span>
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums text-gray-300 font-mono">
                                {o.filled_qty}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-300">
                                {if o.filled_avg_price,
                                  do: "$#{:erlang.float_to_binary(o.filled_avg_price, decimals: 2)}",
                                  else: "—"}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 text-[10px] text-gray-500 font-mono">
                                <%= if o.submitted_at do %>
                                  <span
                                    id={"alpaca-order-time-#{o.id || o.symbol}"}
                                    phx-hook="LocalTime"
                                    data-iso={o.submitted_at}
                                    data-format="datetime"
                                  >
                                    {String.slice(o.submitted_at, 0, 16) |> String.replace("T", " ")}
                                  </span>
                                <% else %>
                                  —
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    <% end %>
                  </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Kalshi Tab --%>
          <%= if @active_tab == :kalshi do %>
            <div class="px-4 sm:px-6 lg:px-8 py-6 space-y-6">
              <%= case @kalshi_data do %>
                <% :loading -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm animate-pulse">Loading Kalshi account...</p>
                  </div>
                <% :not_configured -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm mb-3">Kalshi API keys not configured.</p>
                    <.link navigate={~p"/api-keys"} class="text-xs font-bold text-white underline">
                      Add keys in Settings →
                    </.link>
                  </div>
                <% :unauthorized -> %>
                  <div class="rounded-2xl border border-red-500/20 bg-red-500/5 p-6 text-center">
                    <p class="text-red-400 text-sm">
                      Kalshi credentials invalid — check your API key and PEM in Settings.
                    </p>
                  </div>
                <% :error -> %>
                  <div class="rounded-2xl border border-yellow-500/20 bg-yellow-500/5 p-6 text-center">
                    <p class="text-yellow-400 text-sm">Could not reach Kalshi API. Try refreshing.</p>
                  </div>
                <% nil -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm">
                      Click the Kalshi tab to load your demo portfolio.
                    </p>
                  </div>
                <% data -> %>
                  <%!-- Account Summary Cards --%>
                  <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
                    <%= for {label, val, color} <- [
                      {"Available Balance", "$#{:erlang.float_to_binary(data.balance.available_balance, decimals: 2)}", "text-white"},
                      {"Portfolio Value", "$#{:erlang.float_to_binary(data.portfolio_value, decimals: 2)}", "text-emerald-400"},
                      {"Settled P&L", "#{if data.total_settled_pnl >= 0, do: "+", else: ""}$#{:erlang.float_to_binary(abs(data.total_settled_pnl), decimals: 2)}", if(data.total_settled_pnl >= 0, do: "text-emerald-400", else: "text-red-400")},
                      {"Open Positions", "#{length(data.positions)}", "text-blue-400"}
                    ] do %>
                      <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                        <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                          {label}
                        </p>
                        <p class={"text-lg font-black tabular-nums #{color}"}>{val}</p>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Quick Trade — trading agents only --%>
                  <%= if @selected_agent && @selected_agent.agent_type == "trading" do %>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                      <div class="flex items-center justify-between mb-4">
                        <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                          Quick Trade
                        </p>
                        <span class="text-[10px] font-mono text-gray-600">
                          KalshiClient · {@selected_agent.name}
                        </span>
                      </div>
                      <form
                        phx-submit="kalshi_quick_trade"
                        class="grid grid-cols-1 sm:grid-cols-5 gap-3 items-end"
                      >
                        <div class="sm:col-span-2">
                          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                            Ticker
                          </label>
                          <input
                            type="text"
                            name="ticker"
                            value={@kalshi_quick_trade_ticker}
                            phx-change="kalshi_quick_trade_ticker"
                            phx-debounce="300"
                            placeholder="KXETHD-25NOV30-B3500"
                            class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono uppercase"
                          />
                        </div>
                        <div>
                          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                            Side
                          </label>
                          <select
                            name="side"
                            phx-change="kalshi_quick_trade_side"
                            class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-sm text-white focus:outline-none focus:border-white/30"
                          >
                            <option value="yes" selected={@kalshi_quick_trade_side == "yes"}>
                              Yes
                            </option>
                            <option value="no" selected={@kalshi_quick_trade_side == "no"}>No</option>
                          </select>
                        </div>
                        <div>
                          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                            Count
                          </label>
                          <input
                            type="number"
                            name="units"
                            min="1"
                            step="1"
                            value={@kalshi_quick_trade_units}
                            phx-change="kalshi_quick_trade_units"
                            phx-debounce="300"
                            class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-sm text-white focus:outline-none focus:border-white/30 tabular-nums"
                          />
                        </div>
                        <div>
                          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                            Limit (¢ 1-99)
                          </label>
                          <input
                            type="number"
                            name="price"
                            min="1"
                            max="99"
                            step="1"
                            value={@kalshi_quick_trade_price}
                            phx-change="kalshi_quick_trade_price"
                            phx-debounce="300"
                            class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-sm text-white focus:outline-none focus:border-white/30 tabular-nums"
                          />
                        </div>
                        <div class="sm:col-span-5 flex items-center justify-between gap-3">
                          <%= case @kalshi_action_flash do %>
                            <% {:ok, msg} -> %>
                              <p class="text-xs text-emerald-400">{msg}</p>
                            <% {:error, msg} -> %>
                              <p class="text-xs text-red-400">{msg}</p>
                            <% _ -> %>
                              <p class="text-[10px] text-gray-600">
                                Routes through PaperExecutionWorker — same pipeline as agent-API submissions. Every trade lands on /trades.
                              </p>
                          <% end %>
                          <button
                            type="submit"
                            class="px-5 py-2 rounded-xl bg-white text-black text-xs uppercase tracking-widest hover:bg-gray-100"
                          >
                            Place Order
                          </button>
                        </div>
                      </form>
                    </div>
                  <% end %>

                  <%!-- Portfolio P&L Curve (cumulative net of fees over settled time) --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <div class="flex items-center justify-between mb-4">
                      <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                        Portfolio P&L
                      </p>
                      <span class={
                        "text-xs font-mono tabular-nums " <>
                          if(data.total_settled_pnl >= 0, do: "text-emerald-400", else: "text-red-400")
                      }>
                        {if data.total_settled_pnl >= 0, do: "+", else: ""}${:erlang.float_to_binary(
                          abs(data.total_settled_pnl),
                          decimals: 2
                        )} · {length(data.settlements)} settled
                      </span>
                    </div>
                    <%= if length(data.settlements) > 1 do %>
                      <% chart_color = if data.total_settled_pnl >= 0, do: "#10b981", else: "#ef4444" %>
                      <% pnl_points = kalshi_pnl_sparkline(data.settlements, 400, 150) %>
                      <% zero_y = kalshi_pnl_zero_y(data.settlements, 150) %>
                      <svg viewBox="0 0 400 160" class="w-full h-40" preserveAspectRatio="none">
                        <line x1="0" y1="40" x2="400" y2="40" stroke="white" stroke-opacity="0.05" />
                        <line x1="0" y1="80" x2="400" y2="80" stroke="white" stroke-opacity="0.05" />
                        <line x1="0" y1="120" x2="400" y2="120" stroke="white" stroke-opacity="0.05" />
                        <%!-- Break-even reference line at zero P&L --%>
                        <line
                          x1="0"
                          y1={zero_y}
                          x2="400"
                          y2={zero_y}
                          stroke="white"
                          stroke-opacity="0.15"
                          stroke-dasharray="3 3"
                        />
                        <defs>
                          <linearGradient id="kalshi-pnl-fill" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stop-color={chart_color} stop-opacity="0.25" />
                            <stop offset="100%" stop-color={chart_color} stop-opacity="0.0" />
                          </linearGradient>
                        </defs>
                        <polygon
                          points={"#{pnl_points} 400,#{zero_y} 0,#{zero_y}"}
                          fill="url(#kalshi-pnl-fill)"
                        />
                        <polyline
                          points={pnl_points}
                          fill="none"
                          stroke={chart_color}
                          stroke-width="2"
                          vector-effect="non-scaling-stroke"
                        />
                      </svg>
                      <div class="flex justify-between mt-2 text-[10px] text-gray-600 font-mono">
                        <span>Oldest settled</span>
                        <span>Latest settled</span>
                      </div>
                    <% else %>
                      <div class="py-10 text-center">
                        <p class="text-sm text-gray-600">
                          {if data.settlements == [],
                            do: "No settled positions yet.",
                            else: "Need at least 2 settled positions to chart P&L."}
                        </p>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Open Positions --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                    <div class="px-6 py-4 border-b border-white/10">
                      <h3 class="text-xs font-black text-white uppercase tracking-widest">
                        Open Positions
                      </h3>
                    </div>
                    <%= if data.positions == [] do %>
                      <p class="px-6 py-8 text-center text-sm text-gray-600">No open positions.</p>
                    <% else %>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ["Market", "Status", "Side", "Contracts", "Avg", "Bid / Ask", "Value"] do %>
                              <th class="px-2 py-2 sm:px-4 sm:py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                                {h}
                              </th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for p <- data.positions do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td
                                class="px-2 py-2 sm:px-4 sm:py-3 text-white text-xs font-mono max-w-[16rem] truncate"
                                title={p.title}
                              >
                                {truncate_market(p.title, 32)}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3">
                                <% {label, badge_classes} = kalshi_status_badge(p.status) %>
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase tracking-widest whitespace-nowrap",
                                  badge_classes
                                ]}>
                                  {label}
                                </span>
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  p.side == "yes" &&
                                    "text-emerald-400 border-emerald-500/20 bg-emerald-500/10",
                                  p.side == "no" && "text-red-400 border-red-500/20 bg-red-500/10"
                                ]}>
                                  {p.side}
                                </span>
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums text-gray-300">
                                {p.contracts}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-400">
                                {:erlang.float_to_binary(p.avg_price * 100, decimals: 0)}¢
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-300">
                                {kalshi_live_quote(p)}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-white">
                                ${:erlang.float_to_binary(p.value, decimals: 2)}
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    <% end %>
                  </div>

                  <%!-- Pending Orders (resting limit orders with Cancel buttons) --%>
                  <%= if Map.get(data, :pending_orders, []) != [] do %>
                    <div class="rounded-2xl border border-amber-500/20 bg-amber-500/5 overflow-x-auto">
                      <div class="px-6 py-4 border-b border-amber-500/20 flex items-center justify-between">
                        <h3 class="text-xs font-black text-amber-400 uppercase tracking-widest">
                          Pending Orders
                        </h3>
                        <span class="text-[10px] text-amber-600 uppercase tracking-widest">
                          {length(data.pending_orders)} resting
                        </span>
                      </div>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ["Market", "Side", "Action", "Qty", "Limit Price", "Created", ""] do %>
                              <th class="px-2 py-2 sm:px-4 sm:py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                                {h}
                              </th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for o <- data.pending_orders do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-2 py-2 sm:px-4 sm:py-3 font-mono text-white text-xs">
                                {o.ticker}
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  o.side == "yes" &&
                                    "text-emerald-400 border-emerald-500/20 bg-emerald-500/10",
                                  o.side == "no" &&
                                    "text-red-400 border-red-500/20 bg-red-500/10"
                                ]}>
                                  {o.side}
                                </span>
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  o.action == "buy" &&
                                    "text-blue-400 border-blue-500/20 bg-blue-500/10",
                                  o.action == "sell" &&
                                    "text-orange-400 border-orange-500/20 bg-orange-500/10"
                                ]}>
                                  {o.action}
                                </span>
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums text-gray-300 font-mono">
                                {o.count}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-300">
                                {:erlang.float_to_binary(o.price * 100, decimals: 0)}¢
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 text-[10px] text-gray-500 font-mono">
                                <%= if o.created_time do %>
                                  {String.slice(o.created_time, 0, 16) |> String.replace("T", " ")}
                                <% else %>
                                  —
                                <% end %>
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3">
                                <%= if o.order_id do %>
                                  <button
                                    phx-click="cancel_kalshi_order"
                                    phx-value-order_id={o.order_id}
                                    data-confirm={"Cancel order #{o.ticker} #{o.side} #{o.count}?"}
                                    class="text-[10px] font-bold text-red-400 border border-red-500/20 bg-red-500/10 px-2 py-1 rounded hover:bg-red-500/20 transition-colors"
                                  >
                                    Cancel
                                  </button>
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  <% end %>

                  <%!-- Recent Fills --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                    <div class="px-6 py-4 border-b border-white/10 flex items-center justify-between">
                      <h3 class="text-xs font-black text-white uppercase tracking-widest">
                        Recent Fills
                      </h3>
                      <span class="text-[10px] text-gray-600 uppercase tracking-widest">
                        via Kalshi Demo
                      </span>
                    </div>
                    <%= if data.fills == [] do %>
                      <p class="px-6 py-8 text-center text-sm text-gray-600">No fills yet.</p>
                    <% else %>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ["Market", "Side", "Action", "Contracts", "Price", "Time"] do %>
                              <th class="px-2 py-2 sm:px-4 sm:py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                                {h}
                              </th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for f <- Enum.take(data.fills, 10) do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-2 py-2 sm:px-4 sm:py-3 font-black text-white text-xs font-mono">
                                {f.ticker}
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  f.side == "yes" &&
                                    "text-emerald-400 border-emerald-500/20 bg-emerald-500/10",
                                  f.side == "no" && "text-red-400 border-red-500/20 bg-red-500/10"
                                ]}>
                                  {f.side}
                                </span>
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  f.action == "buy" &&
                                    "text-blue-400 border-blue-500/20 bg-blue-500/10",
                                  f.action == "sell" &&
                                    "text-orange-400 border-orange-500/20 bg-orange-500/10"
                                ]}>
                                  {f.action}
                                </span>
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums text-gray-300 font-mono">
                                {f.count}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono text-gray-300">
                                {:erlang.float_to_binary(f.price * 100, decimals: 0)}¢
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 text-[10px] text-gray-500 font-mono">
                                <%= if f.created_time do %>
                                  <span
                                    id={"kalshi-fill-time-#{f.trade_id || f.ticker}"}
                                    phx-hook="LocalTime"
                                    data-iso={f.created_time}
                                    data-format="datetime"
                                  >
                                    {String.slice(f.created_time, 0, 16) |> String.replace("T", " ")}
                                  </span>
                                <% else %>
                                  —
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    <% end %>
                  </div>

                  <%!-- Settlements --%>
                  <%= if data.settlements != [] do %>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                      <div class="px-6 py-4 border-b border-white/10">
                        <h3 class="text-xs font-black text-white uppercase tracking-widest">
                          Settlements
                        </h3>
                      </div>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ["Market", "Result", "Revenue", "Settled"] do %>
                              <th class="px-2 py-2 sm:px-4 sm:py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">
                                {h}
                              </th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for s <- Enum.take(data.settlements, 10) do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-2 py-2 sm:px-4 sm:py-3 font-black text-white text-xs font-mono">
                                {s.ticker}
                              </td>
                              <td class="px-4 py-3">
                                <span class={[
                                  "text-[10px] font-black px-2 py-1 rounded border uppercase",
                                  s.market_result == "yes" &&
                                    "text-emerald-400 border-emerald-500/20 bg-emerald-500/10",
                                  s.market_result == "no" &&
                                    "text-red-400 border-red-500/20 bg-red-500/10"
                                ]}>
                                  {s.market_result || "—"}
                                </span>
                              </td>
                              <td class={"px-2 py-2 sm:px-4 sm:py-3 tabular-nums font-mono font-bold #{if s.revenue >= 0, do: "text-emerald-400", else: "text-red-400"}"}>
                                {if s.revenue >= 0, do: "+", else: ""}${:erlang.float_to_binary(
                                  abs(s.revenue),
                                  decimals: 2
                                )}
                              </td>
                              <td class="px-2 py-2 sm:px-4 sm:py-3 text-[10px] text-gray-500 font-mono">
                                <%= if s.settled_time do %>
                                  <span
                                    id={"kalshi-settle-time-#{s.ticker}"}
                                    phx-hook="LocalTime"
                                    data-iso={s.settled_time}
                                    data-format="datetime"
                                  >
                                    {String.slice(s.settled_time, 0, 16) |> String.replace("T", " ")}
                                  </span>
                                <% else %>
                                  —
                                <% end %>
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    </div>
                  <% end %>
              <% end %>
            </div>
          <% end %>

          <%!-- ═══════════════ POLYMARKET TAB ═══════════════ --%>
          <%= if @active_tab == :polymarket do %>
            <% agent_can_trade = @selected_agent && Polymarket.can_trade?(@selected_agent) %>
            <div class="w-full px-4 sm:px-6 lg:px-8 py-8">
              <div class="flex items-center justify-between mb-6 gap-3 flex-wrap">
                <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">
                  Polymarket
                </h2>
                <div class="flex items-center gap-2">
                  <%= if @selected_agent && not agent_can_trade do %>
                    <span class="text-[10px] px-2 py-1 rounded-full uppercase tracking-widest bg-white/5 text-gray-400 border border-white/10">
                      View only
                    </span>
                  <% end %>
                  <span class={[
                    "text-[10px] px-2 py-1 rounded-full uppercase tracking-widest",
                    if(@polymarket_mode == :live,
                      do: "bg-amber-500/20 text-amber-300 border border-amber-500/40",
                      else: "bg-emerald-500/10 text-emerald-300 border border-emerald-500/30"
                    )
                  ]}>
                    {@polymarket_mode} mode
                  </span>
                </div>
              </div>

              <%!-- Paper positions --%>
              <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 mb-6">
                <p class="text-xs text-gray-500 uppercase tracking-widest mb-4 font-bold">
                  {if @selected_agent, do: "Agent Paper Positions", else: "All Org Paper Positions"}
                </p>
                <%= cond do %>
                  <% @polymarket_positions == [] -> %>
                    <p class="text-xs text-gray-500 py-2">No paper positions yet.</p>
                  <% true -> %>
                    <div class="space-y-2">
                      <%= for pos <- @polymarket_positions do %>
                        <div class="flex items-center justify-between py-2 border-b border-white/5 last:border-0">
                          <div class="min-w-0">
                            <p class="text-sm font-bold text-white truncate" title={pos.market_id}>
                              {truncate_market(pos.market_id, 40)}
                            </p>
                            <p class="text-[10px] text-gray-500 uppercase tracking-widest">
                              {pos.outcome} · {pos.mode}
                            </p>
                          </div>
                          <div class="text-right">
                            <p class="text-sm font-mono text-white">{pos.size}</p>
                            <p class="text-[10px] text-gray-500 font-mono">@ {pos.avg_price}</p>
                          </div>
                        </div>
                      <% end %>
                    </div>
                <% end %>
              </div>

              <%!-- Market browser --%>
              <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                <p class="text-xs text-gray-500 uppercase tracking-widest mb-4 font-bold">
                  Trending Markets (Gamma API)
                </p>
                <%= cond do %>
                  <% @polymarket_data == :loading -> %>
                    <div class="flex items-center gap-3 text-gray-500 py-4">
                      <div class="w-4 h-4 border-2 border-white/20 border-t-white/60 rounded-full animate-spin">
                      </div>
                      <span class="text-xs">Loading markets...</span>
                    </div>
                  <% is_list(@polymarket_data) && @polymarket_data != [] -> %>
                    <div class="space-y-3">
                      <%= for market <- @polymarket_data do %>
                        <div class="py-3 border-b border-white/5 last:border-0">
                          <div class="flex items-start justify-between gap-4">
                            <div class="min-w-0 flex-1">
                              <p class="text-sm font-bold text-white">
                                {Polymarket.market_field(
                                  market,
                                  "question",
                                  Polymarket.market_field(market, "slug", "—")
                                )}
                              </p>
                              <p class="text-[10px] text-gray-500 font-mono mt-1 truncate">
                                {Polymarket.market_field(
                                  market,
                                  "conditionId",
                                  Polymarket.market_field(market, "id", "")
                                )}
                              </p>
                            </div>
                            <div class="text-right shrink-0">
                              <% prices =
                                try do
                                  KiteAgentHub.TradingPlatforms.PolymarketClient.extract_prices(
                                    market
                                  )
                                rescue
                                  _ -> %{}
                                end %>
                              <p class="text-xs font-mono text-emerald-300">
                                YES {Polymarket.format_price(Map.get(prices || %{}, "yes"))}
                              </p>
                              <p class="text-xs font-mono text-red-300">
                                NO {Polymarket.format_price(Map.get(prices || %{}, "no"))}
                              </p>
                            </div>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% true -> %>
                    <p class="text-xs text-gray-500 py-2">
                      No markets returned. Gamma API may be rate-limited or unreachable.
                    </p>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- ═══════════════ FOREX TAB ═══════════════ --%>
          <%= if @active_tab == :forex do %>
            <% forex_agent_can_trade =
              @selected_agent &&
                Oanda.can_trade?(@selected_agent) %>
            <% forex_provider_label =
              case {@forex_provider, @forex_oanda_env} do
                {:oanda, :live} -> "OANDA Live"
                {:oanda, _} -> "OANDA Practice"
                {:none, _} -> "ForEx"
                _ -> "no provider"
              end %>
            <div class="w-full px-4 sm:px-6 lg:px-8 py-8">
              <div class="flex items-center justify-between mb-6 gap-3 flex-wrap">
                <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">
                  ForEx ({forex_provider_label})
                </h2>
                <div class="flex items-center gap-2">
                  <%= if @selected_agent && not forex_agent_can_trade do %>
                    <span class="text-[10px] px-2 py-1 rounded-full uppercase tracking-widest bg-white/5 text-gray-400 border border-white/10">
                      View only
                    </span>
                  <% end %>
                  <span class={[
                    "text-[10px] px-2 py-1 rounded-full uppercase tracking-widest border",
                    if(@forex_oanda_env == :live,
                      do: "bg-red-500/20 text-red-200 border-red-500/40",
                      else: "bg-emerald-500/10 text-emerald-300 border-emerald-500/30"
                    )
                  ]}>
                    {cond do
                      @forex_oanda_env == :live -> "Live"
                      @forex_provider == :oanda -> "Practice"
                      true -> "Demo"
                    end}
                  </span>
                </div>
              </div>

              <%!-- Action flash (quick-trade success/error). Solid backgrounds
                 with white text so the message is readable on both
                 dark and light themes. Cleared on next forex_symbol
                 change or any successful action. --%>
              <%= case @forex_action_flash do %>
                <% {:ok, msg} -> %>
                  <div class="mb-4 rounded-xl border border-emerald-700 bg-emerald-600 px-4 py-3 text-xs text-white font-mono shadow-md">
                    {msg}
                  </div>
                <% {:error, msg} -> %>
                  <div class="mb-4 rounded-xl border border-red-700 bg-red-600 px-4 py-3 text-xs text-white font-mono shadow-md">
                    {msg}
                  </div>
                <% _ -> %>
              <% end %>

              <%!-- Live bid/ask quote pill (mirrors OANDA's chart-overlay
                 SELL/BUY pill from their web UI). Only renders when we
                 actually have pricing for the selected symbol. --%>
              <%= if is_map(@forex_pricing) do %>
                <% bid = best_bid(@forex_pricing)
                ask = best_ask(@forex_pricing)
                spread = quote_spread(@forex_pricing) %>
                <div class="mb-6 inline-flex items-center gap-3 rounded-xl border border-white/10 bg-white/[0.03] px-4 py-2">
                  <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                    {Oanda.field(@forex_pricing, "instrument", @forex_symbol)}
                  </span>
                  <span class="text-[10px] font-bold text-red-300 uppercase tracking-widest">
                    SELL
                  </span>
                  <span class="text-sm font-mono text-white tabular-nums">{bid || "—"}</span>
                  <span class="text-[10px] text-gray-500 font-mono">spread {spread || "—"}</span>
                  <span class="text-[10px] font-bold text-blue-300 uppercase tracking-widest">
                    BUY
                  </span>
                  <span class="text-sm font-mono text-white tabular-nums">{ask || "—"}</span>
                  <%= if Map.get(@forex_pricing, "tradeable") == false do %>
                    <span class="text-[10px] font-bold text-yellow-300 uppercase tracking-widest">
                      market closed
                    </span>
                  <% end %>
                </div>
              <% end %>

              <%!-- Account summary (OANDA only) — hedge-fund-style hero
                   + 4-up KPI strip + session NAV sparkline. Mirrors the
                   Portfolio tab pattern Mico approved for the redesign
                   sweep. Numbers parsed to floats so anime.js CountUp
                   can animate them; OANDA's `account_summary` returns
                   strings on the wire. --%>
              <%= if @forex_provider == :oanda and is_map(@forex_account) do %>
                <% nav_f = forex_nav_value(@forex_account) || 0.0 %>
                <% balance_f = forex_field_float(@forex_account, "balance") %>
                <% upl_f = forex_field_float(@forex_account, "unrealizedPL") %>
                <% margin_f = forex_field_float(@forex_account, "marginUsed") %>
                <% upl_pct = if nav_f > 0.0, do: upl_f / nav_f * 100.0, else: 0.0 %>

                <%!-- HERO: huge NAV + Unrealized P&L delta pill --%>
                <div class="relative overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-white/[0.04] via-white/[0.02] to-transparent p-8 sm:p-10 mb-4 backdrop-blur-md">
                  <div
                    class="pointer-events-none absolute -top-32 -right-32 w-96 h-96 rounded-full opacity-20 blur-3xl"
                    style={
                      cond do
                        upl_f >= 0 ->
                          "background: radial-gradient(circle, rgba(34,197,94,0.35), transparent 65%);"

                        true ->
                          "background: radial-gradient(circle, rgba(239,68,68,0.25), transparent 65%);"
                      end
                    }
                  />
                  <div class="relative flex flex-col gap-6">
                    <div class="flex items-start justify-between gap-4">
                      <p class="text-[10px] sm:text-xs font-black text-gray-500 uppercase tracking-[0.3em]">
                        OANDA Net Asset Value
                      </p>
                      <span class="hidden sm:inline-flex items-center gap-2 px-3 py-1 rounded-full border border-white/10 bg-white/[0.04] text-[10px] font-mono text-gray-500">
                        <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 shadow-[0_0_8px_#22c55e] animate-pulse">
                        </span>
                        {length(@forex_positions)} positions · {forex_provider_label}
                      </span>
                    </div>
                    <h2 class="text-5xl sm:text-6xl lg:text-7xl font-black tabular-nums tracking-tight text-white leading-none flex items-baseline">
                      <span class="text-gray-500 font-light">$</span>
                      <span
                        id="forex-hero-nav"
                        phx-hook="CountUp"
                        data-target={nav_f}
                        data-decimals="2"
                      >
                        {:erlang.float_to_binary(nav_f, decimals: 2)}
                      </span>
                    </h2>
                    <div class="flex flex-wrap items-baseline gap-4">
                      <div class={[
                        "inline-flex items-center gap-3 px-4 py-2 rounded-xl font-mono text-base sm:text-lg font-bold tabular-nums shadow-lg",
                        upl_f >= 0 && "bg-emerald-600 text-white",
                        upl_f < 0 && "bg-red-600 text-white"
                      ]}>
                        <span class="text-[9px] uppercase tracking-[0.2em] text-white/70 border-r border-white/30 pr-3">
                          Unrealized
                        </span>
                        <span>{if upl_f >= 0, do: "▲", else: "▼"}</span>
                        <span>${:erlang.float_to_binary(abs(upl_f), decimals: 2)}</span>
                        <span class="text-xs text-white/80">
                          ({:erlang.float_to_binary(abs(upl_pct), decimals: 2)}%)
                        </span>
                      </div>
                      <p class="text-[11px] text-gray-500 italic">
                        Mark-to-market across all open OANDA positions
                      </p>
                    </div>
                  </div>
                </div>

                <%!-- 4-up KPI strip --%>
                <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mb-4">
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                    <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                      Balance
                    </p>
                    <p class="text-xl sm:text-2xl font-black tabular-nums text-white">
                      <span class="text-gray-500 font-light">$</span><span
                        id="forex-kpi-balance"
                        phx-hook="CountUp"
                        data-target={balance_f}
                        data-decimals="2"
                      >{:erlang.float_to_binary(balance_f, decimals: 2)}</span>
                    </p>
                    <p class="text-[10px] text-gray-600 mt-1">Settled cash</p>
                  </div>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                    <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                      NAV
                    </p>
                    <p class="text-xl sm:text-2xl font-black tabular-nums text-emerald-400">
                      <span class="text-gray-500 font-light">$</span><span
                        id="forex-kpi-nav"
                        phx-hook="CountUp"
                        data-target={nav_f}
                        data-decimals="2"
                      >{:erlang.float_to_binary(nav_f, decimals: 2)}</span>
                    </p>
                    <p class="text-[10px] text-gray-600 mt-1">Balance + UPL</p>
                  </div>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                    <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                      Unrealized P&L
                    </p>
                    <p class={[
                      "text-xl sm:text-2xl font-black tabular-nums",
                      upl_f >= 0 && "text-emerald-400",
                      upl_f < 0 && "text-red-400"
                    ]}>
                      {if upl_f >= 0, do: "+", else: "-"}<span class="text-gray-500 font-light">$</span>
                      <span
                        id="forex-kpi-upl"
                        phx-hook="CountUp"
                        data-target={abs(upl_f)}
                        data-decimals="2"
                      >
                        {:erlang.float_to_binary(abs(upl_f), decimals: 2)}
                      </span>
                    </p>
                    <p class="text-[10px] text-gray-600 mt-1">Mark-to-market</p>
                  </div>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                    <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                      Margin Used
                    </p>
                    <p class="text-xl sm:text-2xl font-black tabular-nums text-gray-300">
                      <span class="text-gray-500 font-light">$</span><span
                        id="forex-kpi-margin"
                        phx-hook="CountUp"
                        data-target={margin_f}
                        data-decimals="2"
                      >{:erlang.float_to_binary(margin_f, decimals: 2)}</span>
                    </p>
                    <p class="text-[10px] text-gray-600 mt-1">Collateral locked</p>
                  </div>
                </div>

                <%!-- Session NAV sparkline. Ring buffer is capped to 288
                     samples (24h × 5-min cadence after #410 settled the
                     warmup burst). Renders only when ≥2 samples so the
                     SVG never receives a malformed `points` attr. --%>
                <div class="rounded-2xl border border-white/10 bg-gradient-to-br from-white/[0.04] via-white/[0.02] to-transparent p-6 mb-6 backdrop-blur-md">
                  <div class="flex items-center justify-between mb-1 flex-wrap gap-2">
                    <p class="text-xs text-gray-500 uppercase tracking-widest font-bold">
                      Session NAV
                    </p>
                    <span class="text-[10px] text-gray-600 font-mono">
                      {length(@forex_nav_history)} samples · 30s cadence
                    </span>
                  </div>
                  <p class="text-[10px] text-gray-600 mb-3 italic">
                    NAV captured since you opened the tab. Capped at 288 samples (~24h of 30s ticks).
                  </p>
                  <% session_chart = session_nav_chart_data(@forex_nav_history, 640, 200) %>
                  <%= cond do %>
                    <% session_chart != :empty -> %>
                      <% c = session_chart %>
                      <% stroke = if c.delta >= 0, do: "#22c55e", else: "#ef4444" %>
                      <%!-- Banner: current NAV + signed-delta pill — same
                           pattern as Alpaca / Forex instrument charts. --%>
                      <div class="flex items-baseline justify-between mb-2 flex-wrap gap-2">
                        <p class="text-2xl font-mono tabular-nums text-white">
                          ${:erlang.float_to_binary(c.last, decimals: 2)}
                        </p>
                        <span class={[
                          "text-xs font-mono tabular-nums px-2 py-0.5 rounded",
                          c.delta >= 0 && "bg-emerald-500/15 text-emerald-300",
                          c.delta < 0 && "bg-red-500/15 text-red-300"
                        ]}>
                          {if c.delta >= 0, do: "+", else: ""}${:erlang.float_to_binary(c.delta,
                            decimals: 2
                          )} ({:erlang.float_to_binary(c.delta_pct, decimals: 2)}%)
                        </span>
                      </div>
                      <div
                        id="forex-nav-chart"
                        phx-hook="CrosshairChart"
                        class="relative"
                        data-points={c.crosshair_data}
                      >
                        <svg
                          viewBox="0 0 700 220"
                          preserveAspectRatio="none"
                          class="w-full h-56 select-none cursor-crosshair"
                        >
                          <defs>
                            <linearGradient id="forex-nav-fill" x1="0" y1="0" x2="0" y2="1">
                              <stop offset="0%" stop-color={stroke} stop-opacity="0.42" />
                              <stop offset="60%" stop-color={stroke} stop-opacity="0.12" />
                              <stop offset="100%" stop-color={stroke} stop-opacity="0.0" />
                            </linearGradient>
                            <filter
                              id="forex-nav-glow"
                              x="-10%"
                              y="-30%"
                              width="120%"
                              height="160%"
                            >
                              <feGaussianBlur stdDeviation="2.2" result="blur" />
                              <feMerge>
                                <feMergeNode in="blur" />
                                <feMergeNode in="SourceGraphic" />
                              </feMerge>
                            </filter>
                          </defs>
                          <g transform="translate(0,10)">
                            <rect
                              x="0"
                              y="0"
                              width="640"
                              height="200"
                              fill="white"
                              fill-opacity="0.03"
                            />
                            <%= for {tick, idx} <- Enum.with_index(c.y_ticks) do %>
                              <line
                                x1="0"
                                y1={tick.y}
                                x2="640"
                                y2={tick.y}
                                stroke="white"
                                stroke-opacity={if idx == 2, do: "0.12", else: "0.05"}
                                stroke-dasharray={if idx == 2, do: "4,4", else: ""}
                              />
                              <text
                                x="648"
                                y={tick.y + 3}
                                fill="rgba(156,163,175,0.7)"
                                font-size="9"
                                font-family="ui-monospace, monospace"
                                text-anchor="start"
                              >
                                ${tick.label}
                              </text>
                            <% end %>
                            <line
                              x1="640"
                              y1="0"
                              x2="640"
                              y2="200"
                              stroke="white"
                              stroke-opacity="0.10"
                            />
                            <path d={c.area_d} fill="url(#forex-nav-fill)" />
                            <path
                              d={c.path_d}
                              fill="none"
                              stroke={stroke}
                              stroke-width="2.25"
                              stroke-linejoin="round"
                              stroke-linecap="round"
                              vector-effect="non-scaling-stroke"
                              filter="url(#forex-nav-glow)"
                            />
                            <line
                              data-crosshair-x
                              x1="0"
                              y1="0"
                              x2="0"
                              y2="200"
                              stroke="white"
                              stroke-opacity="0.45"
                              stroke-width="0.5"
                              stroke-dasharray="2,3"
                              class="hidden"
                            />
                            <circle
                              data-crosshair-dot
                              cx="0"
                              cy="0"
                              r="4.5"
                              fill={stroke}
                              stroke="white"
                              stroke-width="1.5"
                              class="hidden"
                            />
                          </g>
                        </svg>
                        <div
                          data-crosshair-tooltip
                          class="hidden absolute pointer-events-none px-3 py-2 rounded-lg bg-gray-900/95 border border-white/15 text-xs font-mono tabular-nums shadow-xl text-white"
                          style="z-index: 5;"
                        >
                          <span data-crosshair-time class="text-gray-300 mr-2"></span>
                          <span data-crosshair-price class="text-white font-semibold"></span>
                        </div>
                      </div>
                      <div class="flex justify-between mt-1 text-[10px] text-gray-600 font-mono tabular-nums pr-[60px]">
                        <span>{Enum.at(c.x_ticks, 0).label}</span>
                        <span>{Enum.at(c.x_ticks, 1).label}</span>
                        <span>{Enum.at(c.x_ticks, 2).label}</span>
                      </div>

                      <%!-- Range + delta strip --%>
                      <div class="grid grid-cols-3 gap-3 mt-3">
                        <div class="rounded-lg border border-white/5 bg-white/[0.02] px-3 py-2">
                          <p class="text-[9px] text-gray-500 uppercase tracking-widest font-bold">
                            Open
                          </p>
                          <p class="text-sm font-mono tabular-nums text-gray-200">
                            ${:erlang.float_to_binary(c.first, decimals: 2)}
                          </p>
                        </div>
                        <div class={[
                          "rounded-lg border px-3 py-2 text-center",
                          c.delta >= 0 && "border-emerald-500/30 bg-emerald-500/[0.06]",
                          c.delta < 0 && "border-red-500/30 bg-red-500/[0.06]"
                        ]}>
                          <p class={[
                            "text-[9px] uppercase tracking-widest font-bold",
                            c.delta >= 0 && "text-emerald-400",
                            c.delta < 0 && "text-red-400"
                          ]}>
                            Session Δ
                          </p>
                          <p class={[
                            "text-sm font-mono tabular-nums font-bold",
                            c.delta >= 0 && "text-emerald-400",
                            c.delta < 0 && "text-red-400"
                          ]}>
                            {if c.delta >= 0, do: "+", else: "-"}${:erlang.float_to_binary(
                              abs(c.delta),
                              decimals: 2
                            )} ({:erlang.float_to_binary(abs(c.delta_pct), decimals: 2)}%)
                          </p>
                        </div>
                        <div class="rounded-lg border border-white/5 bg-white/[0.02] px-3 py-2 text-right">
                          <p class="text-[9px] text-gray-500 uppercase tracking-widest font-bold">
                            Range
                          </p>
                          <p class="text-sm font-mono tabular-nums text-gray-200">
                            ${:erlang.float_to_binary(c.min, decimals: 2)} – ${:erlang.float_to_binary(
                              c.max,
                              decimals: 2
                            )}
                          </p>
                        </div>
                      </div>
                    <% true -> %>
                      <div class="py-10 text-center">
                        <div class="w-12 h-1 mx-auto rounded-full bg-emerald-500/30 overflow-hidden mb-4">
                          <div class="h-full w-1/3 bg-emerald-400 animate-pulse rounded-full"></div>
                        </div>
                        <p class="text-xs text-gray-400 uppercase tracking-widest">
                          Building chart…
                        </p>
                        <p class="text-[10px] text-gray-600 mt-2">
                          Capturing NAV samples — first chart appears in under 10s.
                        </p>
                        <p class="text-[10px] text-gray-700 mt-1 font-mono">
                          {length(@forex_nav_history)} / 2 samples
                        </p>
                      </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Chart (OANDA candles only) — rich instrument view:
                   gradient area fill, 20-period MA dotted overlay,
                   right-side Y-axis price ticks, X-axis time labels,
                   pointermove crosshair + tooltip. Data is all
                   server-computed by `forex_instrument_chart_data/4`;
                   the `CrosshairChart` hook reads pre-encoded JSON
                   from `data-points` and only writes textContent /
                   classList / setAttribute (CyberSec 13769). --%>
              <%= if @forex_provider == :oanda and @forex_candles != [] do %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 mb-6">
                  <div class="flex items-center justify-between mb-1 flex-wrap gap-2">
                    <p class="text-xs text-gray-500 uppercase tracking-widest">
                      {@forex_symbol} — last 10h
                    </p>
                    <div class="flex items-center gap-1.5">
                      <%= for {label, code, hint} <- [
                        {"Mid", "M", "Midpoint of bid and ask — standard chart view"},
                        {"Bid", "B", "Sell price — what you receive when going short"},
                        {"Ask", "A", "Buy price — what you pay when going long"}
                      ] do %>
                        <button
                          type="button"
                          phx-click="forex_chart_price"
                          phx-value-price={code}
                          title={hint}
                          class={[
                            "px-2.5 py-1 rounded-md text-[10px] uppercase tracking-widest transition-colors",
                            if(@forex_chart_price == code,
                              do: "bg-emerald-600 text-white border border-emerald-700 shadow-sm",
                              else:
                                "bg-black/30 text-gray-400 border border-white/10 hover:text-white hover:border-white/20"
                            )
                          ]}
                        >
                          {label}
                        </button>
                      <% end %>
                    </div>
                  </div>
                  <p class="text-[10px] text-gray-600 mb-3">
                    {chart_caption(@forex_chart_price)}
                  </p>
                  <% chart = forex_instrument_chart_data(@forex_candles, @forex_chart_price, 640, 200) %>
                  <%= case chart do %>
                    <% :empty -> %>
                      <p class="text-xs text-gray-500 py-2">No chart data yet.</p>
                    <% c -> %>
                      <% stroke = if c.delta >= 0, do: "#22c55e", else: "#ef4444" %>
                      <%!-- Last-price banner + Δ pill above chart --%>
                      <div class="flex items-baseline justify-between mb-2 flex-wrap gap-2">
                        <p class="text-2xl font-mono tabular-nums text-white">
                          {:erlang.float_to_binary(c.last, decimals: c.decimals)}
                        </p>
                        <span class={[
                          "text-xs font-mono tabular-nums px-2 py-0.5 rounded",
                          c.delta >= 0 && "bg-emerald-500/15 text-emerald-300",
                          c.delta < 0 && "bg-red-500/15 text-red-300"
                        ]}>
                          {if c.delta >= 0, do: "+", else: ""}{:erlang.float_to_binary(c.delta,
                            decimals: c.decimals
                          )} ({:erlang.float_to_binary(c.delta_pct, decimals: 2)}%)
                        </span>
                      </div>
                      <%!-- Chart container — CrosshairChart hook reads
                           `data-points` (server-encoded JSON) and writes
                           textContent only. Outer div is `position: relative`
                           so the tooltip can be absolutely positioned over
                           the SVG. --%>
                      <div
                        id="forex-instrument-chart"
                        phx-hook="CrosshairChart"
                        class="relative"
                        data-points={c.crosshair_data}
                      >
                        <svg
                          viewBox="0 0 700 220"
                          preserveAspectRatio="none"
                          class="w-full h-56 select-none cursor-crosshair"
                        >
                          <defs>
                            <linearGradient id="forex-chart-fill" x1="0" y1="0" x2="0" y2="1">
                              <stop offset="0%" stop-color={stroke} stop-opacity="0.42" />
                              <stop offset="60%" stop-color={stroke} stop-opacity="0.12" />
                              <stop offset="100%" stop-color={stroke} stop-opacity="0.0" />
                            </linearGradient>
                            <%!-- Soft drop-shadow glow under the price path —
                                 server SVG filter only, no JS. CyberSec 13796 ②. --%>
                            <filter
                              id="forex-chart-glow"
                              x="-10%"
                              y="-30%"
                              width="120%"
                              height="160%"
                            >
                              <feGaussianBlur stdDeviation="2.2" result="blur" />
                              <feMerge>
                                <feMergeNode in="blur" />
                                <feMergeNode in="SourceGraphic" />
                              </feMerge>
                            </filter>
                          </defs>
                          <%!-- Plot area is x=0..640 inside a 700-wide viewBox;
                               the 60px right margin is for price labels. The
                               `g` shifts everything down 10px so the top tick
                               label doesn't get clipped. --%>
                          <g transform="translate(0,10)">
                            <%= for {tick, idx} <- Enum.with_index(c.y_ticks) do %>
                              <line
                                x1="0"
                                y1={tick.y}
                                x2="640"
                                y2={tick.y}
                                stroke="white"
                                stroke-opacity={if idx == 2, do: "0.12", else: "0.05"}
                                stroke-dasharray={if idx == 2, do: "4,4", else: ""}
                              />
                              <text
                                x="648"
                                y={tick.y + 3}
                                fill="rgba(156,163,175,0.7)"
                                font-size="9"
                                font-family="ui-monospace, monospace"
                                text-anchor="start"
                              >
                                {tick.label}
                              </text>
                            <% end %>
                            <%!-- Vertical separator between plot area and the
                                 right-axis price ticks. --%>
                            <line
                              x1="640"
                              y1="0"
                              x2="640"
                              y2="200"
                              stroke="white"
                              stroke-opacity="0.10"
                            />
                            <path d={c.area_d} fill="url(#forex-chart-fill)" />
                            <%= if c.ma_path_d != "" do %>
                              <path
                                d={c.ma_path_d}
                                fill="none"
                                stroke="#f59e0b"
                                stroke-opacity="0.7"
                                stroke-width="1"
                                stroke-dasharray="3,3"
                                vector-effect="non-scaling-stroke"
                              />
                            <% end %>
                            <path
                              d={c.path_d}
                              fill="none"
                              stroke={stroke}
                              stroke-width="2.25"
                              stroke-linejoin="round"
                              stroke-linecap="round"
                              vector-effect="non-scaling-stroke"
                              filter="url(#forex-chart-glow)"
                            />
                            <line
                              data-crosshair-x
                              x1="0"
                              y1="0"
                              x2="0"
                              y2="200"
                              stroke="white"
                              stroke-opacity="0.45"
                              stroke-width="0.5"
                              stroke-dasharray="2,3"
                              class="hidden"
                            />
                            <%!-- Hover dot — hook sets cx/cy + classList on
                                 pointermove. CyberSec 13796 ③: setAttribute
                                 only, no innerHTML. --%>
                            <circle
                              data-crosshair-dot
                              cx="0"
                              cy="0"
                              r="4.5"
                              fill={stroke}
                              stroke="white"
                              stroke-width="1.5"
                              class="hidden"
                            />
                          </g>
                        </svg>
                        <%!-- Tooltip — hook toggles `hidden`, writes time/
                             price via textContent only (CyberSec 13769). --%>
                        <div
                          data-crosshair-tooltip
                          class="hidden absolute pointer-events-none px-3 py-2 rounded-lg bg-gray-900/95 border border-white/15 text-xs font-mono tabular-nums shadow-xl text-white"
                          style="z-index: 5;"
                        >
                          <span data-crosshair-time class="text-gray-400 mr-2"></span>
                          <span data-crosshair-price class="text-white"></span>
                        </div>
                      </div>
                      <%!-- X-axis time labels --%>
                      <div class="flex justify-between mt-1 text-[10px] text-gray-600 font-mono tabular-nums pr-[60px]">
                        <span>{Enum.at(c.x_ticks, 0).label}</span>
                        <span>{Enum.at(c.x_ticks, 1).label}</span>
                        <span>{Enum.at(c.x_ticks, 2).label}</span>
                      </div>
                      <%!-- Legend strip --%>
                      <div class="flex items-center justify-between mt-3 text-[10px] text-gray-500 font-mono flex-wrap gap-2">
                        <span class="inline-flex items-center gap-1.5">
                          <span class={[
                            "inline-block w-3 h-[2px] rounded",
                            c.delta >= 0 && "bg-emerald-400",
                            c.delta < 0 && "bg-red-400"
                          ]}>
                          </span>
                          Price ({chart_caption_short(@forex_chart_price)})
                        </span>
                        <%= if c.ma_path_d != "" do %>
                          <span class="inline-flex items-center gap-1.5 text-amber-300/80">
                            <span class="inline-block w-3 border-t border-dashed border-amber-400">
                            </span>
                            MA-20
                          </span>
                        <% end %>
                        <span>
                          Hi {:erlang.float_to_binary(c.max, decimals: c.decimals)} · Lo {:erlang.float_to_binary(
                            c.min,
                            decimals: c.decimals
                          )}
                        </span>
                      </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Quick Trade — practice-only ticket. Hidden when no
                 trading agent is selected or OANDA is not wired up.
                 Buy/Sell open a confirmation modal first; the actual
                 forex_quick_trade event only fires from the modal
                 confirm button so a misclick can not place an order. --%>
              <%= if forex_agent_can_trade and @forex_provider == :oanda and @forex_oanda_env == :practice do %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 mb-6">
                  <div class="flex items-center justify-between mb-4">
                    <p class="text-xs text-gray-500 uppercase tracking-widest font-bold">
                      Quick Trade ({@forex_symbol})
                    </p>
                    <span class="text-[10px] font-bold text-gray-600 uppercase tracking-widest">
                      Practice — submits a market order
                    </span>
                  </div>
                  <form
                    id="forex-quick-trade-form"
                    phx-hook="QuickTradeForm"
                    phx-submit="forex_quick_trade_review"
                    class="flex flex-wrap items-end gap-3"
                  >
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-gray-500 uppercase tracking-widest font-bold">
                        Units
                      </label>
                      <input
                        type="number"
                        name="units"
                        min="1"
                        step="1"
                        value={@forex_quick_trade_units}
                        class="w-32 bg-black/40 border border-white/20 rounded-xl px-3 py-2 text-sm text-white focus:outline-none focus:border-white/40 font-mono"
                      />
                    </div>
                    <button
                      type="submit"
                      name="side"
                      value="sell"
                      class="px-5 py-2 rounded-xl bg-red-600 hover:bg-red-500 border border-red-700 text-white text-xs uppercase tracking-widest transition-colors shadow-md"
                    >
                      Sell
                    </button>
                    <button
                      type="submit"
                      name="side"
                      value="buy"
                      class="px-5 py-2 rounded-xl bg-blue-600 hover:bg-blue-500 border border-blue-700 text-white text-xs uppercase tracking-widest transition-colors shadow-md"
                    >
                      Buy
                    </button>
                    <p class="text-[10px] text-gray-600 mt-2 basis-full">
                      Routes through the same PaperExecutionWorker as the agent API — every dashboard trade creates a TradeRecord and lands on the Trades tab.
                    </p>
                  </form>
                </div>
              <% end %>

              <%!-- Trade confirmation modal. Opens via forex_quick_trade_review
                 event; user must explicitly click "Confirm" to actually
                 enqueue the order. Estimated USD cost is computed from
                 the current ASK (buy) or BID (sell) on the live quote
                 we already have in @forex_pricing. --%>
              <%= if @forex_pending_trade do %>
                <% pt = @forex_pending_trade
                est = estimated_notional(pt, @forex_pricing) %>
                <div
                  class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm"
                  phx-click="forex_quick_trade_cancel"
                >
                  <div
                    class="relative w-full max-w-md mx-4 rounded-2xl border border-white/20 bg-[#0a0a0f] shadow-2xl overflow-hidden"
                    phx-click-away="forex_quick_trade_cancel"
                  >
                    <div class="px-6 py-4 border-b border-white/10">
                      <h2 class="text-sm font-black text-white uppercase tracking-widest">
                        Confirm trade
                      </h2>
                      <p class="text-[11px] text-gray-500 mt-0.5">
                        Practice account — no real money. Still, double-check.
                      </p>
                    </div>

                    <div class="px-6 py-5 space-y-3 text-sm">
                      <div class="flex items-center justify-between border-b border-white/5 py-2">
                        <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                          Side
                        </span>
                        <span class={[
                          "text-xs font-black px-2.5 py-1 rounded-md uppercase tracking-widest text-white",
                          if(pt.side == "buy", do: "bg-blue-600", else: "bg-red-600")
                        ]}>
                          {pt.side}
                        </span>
                      </div>
                      <div class="flex items-center justify-between border-b border-white/5 py-2">
                        <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                          Instrument
                        </span>
                        <span class="text-sm font-mono text-white">{pt.symbol}</span>
                      </div>
                      <div class="flex items-center justify-between border-b border-white/5 py-2">
                        <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                          Units
                        </span>
                        <span class="text-sm font-mono text-white">{pt.units}</span>
                      </div>
                      <%= if est do %>
                        <div class="flex items-center justify-between border-b border-white/5 py-2">
                          <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                            Est. notional
                          </span>
                          <span class="text-sm font-mono text-white">{est}</span>
                        </div>
                      <% end %>
                    </div>

                    <div class="px-6 py-3 border-t border-white/10">
                      <label class="flex items-center gap-2 text-[11px] text-gray-400 cursor-pointer">
                        <input
                          type="checkbox"
                          id="kah-skip-confirm-checkbox"
                          class="h-3.5 w-3.5 rounded border-white/30 bg-black/40"
                        />
                        <span>Do not ask me again on this device</span>
                      </label>
                    </div>

                    <div class="px-6 py-4 bg-white/[0.03] border-t border-white/10 flex items-center gap-3">
                      <button
                        type="button"
                        phx-click="forex_quick_trade_cancel"
                        class="flex-1 py-2.5 rounded-xl border border-white/20 text-gray-300 hover:text-white hover:border-white/40 text-xs uppercase tracking-widest transition-all"
                      >
                        Cancel
                      </button>
                      <button
                        type="button"
                        id="kah-quick-trade-confirm-btn"
                        phx-hook="QuickTradeConfirm"
                        phx-click="forex_quick_trade_confirm"
                        class={[
                          "flex-[2] py-2.5 rounded-xl text-white text-xs uppercase tracking-widest transition-colors shadow-md",
                          if(pt.side == "buy",
                            do: "bg-blue-600 hover:bg-blue-500 border border-blue-700",
                            else: "bg-red-600 hover:bg-red-500 border border-red-700"
                          )
                        ]}
                      >
                        Confirm {String.upcase(pt.side)} {pt.units} {pt.symbol}
                      </button>
                    </div>
                  </div>
                </div>
              <% end %>

              <%!-- Open positions --%>
              <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 mb-6">
                <p class="text-xs text-gray-500 uppercase tracking-widest mb-4 font-bold">
                  Open Positions
                </p>
                <%= cond do %>
                  <% @forex_loading -> %>
                    <div class="flex items-center gap-3 text-gray-500 py-4">
                      <div class="w-4 h-4 border-2 border-white/20 border-t-white/60 rounded-full animate-spin">
                      </div>
                      <span class="text-xs">Loading…</span>
                    </div>
                  <% is_list(@forex_positions) && @forex_positions != [] -> %>
                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                      <%= for pos <- @forex_positions, view = forex_view(pos, @forex_pricing_by_instrument), view != nil do %>
                        <% up? = view.pct_move >= 0 %>
                        <% pl_color = if view.upl >= 0, do: "text-emerald-400", else: "text-red-400" %>
                        <% pct_color = if up?, do: "text-emerald-400", else: "text-red-400" %>
                        <% pct_bg =
                          if up?,
                            do: "bg-emerald-500/10 border-emerald-500/30",
                            else: "bg-red-500/10 border-red-500/30" %>
                        <% direction_color =
                          if view.side == "long",
                            do: "bg-emerald-500/15 border-emerald-500/40 text-emerald-300",
                            else: "bg-red-500/15 border-red-500/40 text-red-300" %>
                        <%!-- Pip-progress bar: visualize where the
                             current price sits relative to entry on a
                             ±1% band. Pure CSS, no async fetch. --%>
                        <% bar_pct =
                          cond do
                            view.pct_move > 1.0 -> 100.0
                            view.pct_move < -1.0 -> 0.0
                            true -> 50.0 + view.pct_move * 50.0
                          end %>
                        <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4 flex flex-col gap-3">
                          <div class="flex items-center justify-between">
                            <div class="flex items-center gap-2.5 min-w-0">
                              <span class="text-base font-bold text-white tabular-nums truncate">
                                {view.instrument}
                              </span>
                              <span class={"shrink-0 px-2 py-0.5 rounded-full text-[10px] uppercase tracking-widest border " <> direction_color}>
                                {view.side}
                              </span>
                            </div>
                            <div class="flex items-center gap-2">
                              <span class={"px-2 py-0.5 rounded-full text-[10px] font-mono font-bold border " <> pct_bg <> " " <> pct_color}>
                                {forex_fmt_pct(view.pct_move)}
                              </span>
                              <%= if forex_agent_can_trade and @forex_oanda_env == :practice do %>
                                <button
                                  phx-click="forex_close_position"
                                  phx-value-instrument={view.instrument}
                                  data-confirm={"Close all open #{view.instrument} on OANDA practice?"}
                                  class="px-2.5 py-1 rounded-lg bg-gray-700 hover:bg-gray-600 border border-gray-600 text-[10px] uppercase tracking-widest text-white transition-colors shadow-sm"
                                >
                                  Close
                                </button>
                              <% end %>
                            </div>
                          </div>

                          <div class="grid grid-cols-3 gap-2 text-[11px]">
                            <div>
                              <p class="text-gray-500 uppercase tracking-widest font-mono mb-0.5">
                                Entry
                              </p>
                              <p class="text-gray-200 font-mono tabular-nums">
                                {forex_fmt_price(view.entry)}
                              </p>
                            </div>
                            <div>
                              <p class="text-gray-500 uppercase tracking-widest font-mono mb-0.5">
                                Current
                              </p>
                              <p class="text-white font-mono tabular-nums">
                                {forex_fmt_price(view.current)}
                              </p>
                            </div>
                            <div class="text-right">
                              <p class="text-gray-500 uppercase tracking-widest font-mono mb-0.5">
                                P&amp;L
                              </p>
                              <p class={"font-mono tabular-nums font-bold " <> pl_color}>
                                {forex_fmt_money(view.upl)}
                              </p>
                            </div>
                          </div>

                          <%!-- Pip-progress bar within ±1% band (sparkline
                               deferred per Phorari msg 8983; OANDA candle
                               fetch per pair is too many HTTP calls for
                               on-tab-load — follow-up if Mico asks). --%>
                          <div class="relative h-1.5 rounded-full bg-white/[0.05] overflow-hidden">
                            <div class="absolute inset-y-0 left-1/2 w-px bg-white/20"></div>
                            <div
                              class={"absolute inset-y-0 " <> if(up?, do: "bg-emerald-500/70 left-1/2", else: "bg-red-500/70 right-1/2")}
                              style={"width: " <> :erlang.float_to_binary(abs(bar_pct - 50.0) * 1.0, decimals: 2) <> "%;"}
                            >
                            </div>
                          </div>

                          <p class="text-[10px] text-gray-500 font-mono uppercase tracking-widest">
                            Units {:erlang.float_to_binary(view.units * 1.0, decimals: 0)}
                          </p>
                        </div>
                      <% end %>
                    </div>
                  <% true -> %>
                    <p class="text-xs text-gray-500 py-2">
                      No open positions. Add OANDA credentials in Settings to connect.
                    </p>
                <% end %>
              </div>

              <%!-- Instruments — clickable bid/ask grid. Click any pair
                   to load it as the active symbol (chart, quote pill,
                   Quick Trade form all re-render against it). Scrolls
                   internally so all 70+ pairs fit without dominating
                   the tab. --%>
              <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 mb-6">
                <div class="flex items-center justify-between mb-4">
                  <p class="text-xs text-gray-500 uppercase tracking-widest font-bold">
                    Instruments — click to load
                  </p>
                  <span class="text-[10px] font-mono text-gray-600">
                    {map_size(@forex_pricing_by_instrument)} live · {length(@forex_instruments)} total
                  </span>
                </div>
                <%= cond do %>
                  <% is_list(@forex_instruments) && @forex_instruments != [] -> %>
                    <div class="max-h-96 overflow-y-auto pr-1 -mr-1">
                      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-1.5">
                        <%= for inst <- @forex_instruments do %>
                          <% name = Oanda.field(inst, "name", Oanda.field(inst, "symbol", "—"))
                          price = Map.get(@forex_pricing_by_instrument, name)
                          bid = best_bid(price)
                          ask = best_ask(price)
                          active? = name == @forex_symbol %>
                          <button
                            type="button"
                            phx-click="forex_symbol"
                            phx-value-symbol={name}
                            class={[
                              "flex items-center justify-between gap-2 px-3 py-2 rounded-lg border transition-all text-left",
                              if(active?,
                                do: "bg-blue-600 border-blue-700 text-white shadow-md",
                                else:
                                  "bg-black/30 border-white/10 hover:bg-white/[0.06] hover:border-white/20 text-gray-200"
                              )
                            ]}
                          >
                            <span class="text-[11px] font-mono truncate">{name}</span>
                            <span class={[
                              "text-[10px] font-mono tabular-nums shrink-0",
                              if(active?, do: "text-white", else: "text-gray-400")
                            ]}>
                              {bid || "—"} / {ask || "—"}
                            </span>
                          </button>
                        <% end %>
                      </div>
                    </div>
                  <% true -> %>
                    <p class="text-xs text-gray-500 py-2">
                      No instruments loaded. Add OANDA credentials in Settings.
                    </p>
                <% end %>
              </div>

              <%!-- Recent OANDA trades — pulled from KAH TradeRecord
                   for the selected agent. Replaces the old chip dump
                   so users actually see history below the tab. --%>
              <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                <div class="flex items-center justify-between mb-4">
                  <p class="text-xs text-gray-500 uppercase tracking-widest font-bold">
                    Recent OANDA Trades
                  </p>
                  <.link
                    navigate={~p"/trades"}
                    class="text-[10px] font-bold text-emerald-400 hover:text-emerald-300 uppercase tracking-widest"
                  >
                    View all →
                  </.link>
                </div>
                <%= cond do %>
                  <% @selected_agent == nil -> %>
                    <p class="text-xs text-gray-500 py-2">
                      Select an agent to see their forex history.
                    </p>
                  <% @forex_recent_trades == [] -> %>
                    <p class="text-xs text-gray-500 py-2">
                      No OANDA trades yet for this agent. Use Quick Trade above or have the agent submit via the API.
                    </p>
                  <% true -> %>
                    <div class="space-y-1.5">
                      <%= for trade <- @forex_recent_trades do %>
                        <div class="flex items-center justify-between gap-3 py-2 px-3 rounded-lg bg-black/20 border border-white/5">
                          <div class="flex items-center gap-3 min-w-0">
                            <span
                              class="text-[10px] text-gray-500 font-mono"
                              phx-hook="LocalTime"
                              id={"oanda-trade-time-#{trade.id}"}
                              data-iso={DateTime.to_iso8601(trade.inserted_at)}
                              data-format="datetime"
                            >
                              {Calendar.strftime(trade.inserted_at, "%b %d %H:%M")}
                            </span>
                            <span class={[
                              "text-[10px] uppercase tracking-widest px-2 py-0.5 rounded text-white",
                              if(trade.side in ["buy", "long"], do: "bg-blue-600", else: "bg-red-600")
                            ]}>
                              {trade.side}
                            </span>
                            <span class="text-xs font-mono text-white truncate">
                              {trade.market || "—"}
                            </span>
                          </div>
                          <div class="flex items-center gap-3 shrink-0">
                            <span class="text-[11px] font-mono text-gray-300">
                              {format_units(trade.contracts)}u
                            </span>
                            <%= if trade.fill_price do %>
                              <span class="text-[11px] font-mono text-gray-400">
                                @ {trade.fill_price}
                              </span>
                            <% end %>
                            <span class={[
                              "text-[10px] uppercase tracking-widest px-2 py-0.5 rounded-full border",
                              case trade.status do
                                "settled" ->
                                  "border-emerald-500/30 bg-emerald-500/10 text-emerald-300"

                                "pending" ->
                                  "border-yellow-500/30 bg-yellow-500/10 text-yellow-300"

                                "failed" ->
                                  "border-red-500/30 bg-red-500/10 text-red-300"

                                "cancelled" ->
                                  "border-gray-500/30 bg-gray-500/10 text-gray-400"

                                _ ->
                                  "border-white/10 bg-white/5 text-gray-400"
                              end
                            ]}>
                              {trade.status}
                            </span>
                          </div>
                        </div>
                      <% end %>
                    </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Portfolio Breakdown Tab — cross-broker pie + headline stats --%>
          <%= if @active_tab == :portfolio do %>
            <% breakdown =
              portfolio_breakdown(
                @alpaca_data,
                @kalshi_data,
                @forex_account,
                @polymarket_positions,
                @pnl_stats
              ) %>
            <% pnl_pct =
              if breakdown.total_value > 0.0,
                do: breakdown.combined_pnl / breakdown.total_value * 100.0,
                else: 0.0 %>
            <% realized_total =
              Enum.reduce(breakdown.slices, 0.0, fn s, acc ->
                if s.key in [:alpaca, :kalshi], do: acc + s.pnl, else: acc
              end) %>
            <% unrealized_total =
              Enum.reduce(breakdown.slices, 0.0, fn s, acc ->
                if s.key in [:forex, :polymarket], do: acc + s.pnl, else: acc
              end) %>

            <div class="px-4 sm:px-6 lg:px-8 py-8 space-y-8">
              <% {pnl_value, pnl_available?, pnl_period_label} =
                portfolio_pnl_for_period(@portfolio_pnl_period, breakdown.combined_pnl) %>
              <% pnl_pct_for_period =
                if pnl_available? and breakdown.total_value > 0.0,
                  do: pnl_value / breakdown.total_value * 100.0,
                  else: 0.0 %>

              <%!-- ═══════════ HERO: huge total value + delta ═══════════ --%>
              <div class="relative overflow-hidden rounded-3xl border border-white/10 bg-gradient-to-br from-white/[0.04] via-white/[0.02] to-transparent p-8 sm:p-10 backdrop-blur-md">
                <%!-- Soft radial sheen — toned down (0.30 -> 0.18) so the
                P&L pill in front always reads cleanly. Mico 9950 red-on-red fix. --%>
                <div
                  class="pointer-events-none absolute -top-32 -right-32 w-96 h-96 rounded-full opacity-20 blur-3xl"
                  style={
                    cond do
                      not pnl_available? ->
                        "background: radial-gradient(circle, rgba(120,120,140,0.35), transparent 65%);"

                      pnl_value >= 0 ->
                        "background: radial-gradient(circle, rgba(34,197,94,0.35), transparent 65%);"

                      true ->
                        "background: radial-gradient(circle, rgba(239,68,68,0.25), transparent 65%);"
                    end
                  }
                />
                <div class="relative flex flex-col gap-6">
                  <div class="flex items-start justify-between gap-4">
                    <p class="text-[10px] sm:text-xs font-black text-gray-500 uppercase tracking-[0.3em]">
                      Total Portfolio Value
                    </p>
                    <span class="hidden sm:inline-flex items-center gap-2 px-3 py-1 rounded-full border border-white/10 bg-white/[0.04] text-[10px] font-mono text-gray-500">
                      <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 shadow-[0_0_8px_#22c55e] animate-pulse">
                      </span>
                      {breakdown.loaded_count}/{length(breakdown.slices)} brokers live
                    </span>
                  </div>
                  <h2 class="text-5xl sm:text-6xl lg:text-7xl font-black tabular-nums tracking-tight text-white leading-none flex items-baseline">
                    <span class="text-gray-500 font-light">$</span>
                    <span
                      id="portfolio-total-value"
                      phx-hook="CountUp"
                      data-target={breakdown.total_value}
                      data-decimals="2"
                    >
                      {:erlang.float_to_binary(breakdown.total_value, decimals: 2)}
                    </span>
                  </h2>

                  <%!-- P&L row: period toggle + pill --%>
                  <div class="flex flex-wrap items-center gap-3">
                    <%!-- Period toggle. Only :all_time has real data today;
                    others surface a "—" placeholder until day_change is wired
                    in. Whitelist enforced server-side (handle_event/set_pnl_period). --%>
                    <div class="inline-flex rounded-xl border border-white/10 bg-black/30 p-1">
                      <%= for {label, period} <- [{"Today", "today"}, {"Week", "week"}, {"Month", "month"}, {"All-Time", "all_time"}] do %>
                        <button
                          phx-click="set_pnl_period"
                          phx-value-period={period}
                          class={[
                            "px-3 py-1 rounded-lg text-[10px] uppercase tracking-widest transition-all",
                            Atom.to_string(@portfolio_pnl_period) == period &&
                              "bg-white/10 text-white shadow-[0_0_10px_rgba(255,255,255,0.05)]",
                            Atom.to_string(@portfolio_pnl_period) != period &&
                              "text-gray-500 hover:text-white"
                          ]}
                        >
                          {label}
                        </button>
                      <% end %>
                    </div>

                    <%!-- Solid pill — opaque colored bg + white text so it pops
                    off the sheen behind it. Mico 9950 red-on-red fix. --%>
                    <%= if pnl_available? do %>
                      <div class={[
                        "inline-flex items-center gap-3 px-4 py-2 rounded-xl font-mono text-base sm:text-lg font-bold tabular-nums shadow-lg",
                        pnl_value >= 0 && "bg-emerald-600 text-white",
                        pnl_value < 0 && "bg-red-600 text-white"
                      ]}>
                        <span class="text-[9px] uppercase tracking-[0.2em] text-white/70 border-r border-white/30 pr-3">
                          {pnl_period_label}
                        </span>
                        <span>{if pnl_value >= 0, do: "▲", else: "▼"}</span>
                        <span>${:erlang.float_to_binary(abs(pnl_value), decimals: 2)}</span>
                        <span class="text-xs text-white/80">
                          ({:erlang.float_to_binary(abs(pnl_pct_for_period), decimals: 2)}%)
                        </span>
                      </div>
                    <% else %>
                      <div class="inline-flex items-center gap-3 px-4 py-2 rounded-xl bg-white/[0.04] border border-white/10 text-gray-400 text-sm">
                        <span class="text-[9px] uppercase tracking-[0.2em] text-gray-500 border-r border-white/10 pr-3">
                          {pnl_period_label}
                        </span>
                        <span class="font-mono">—</span>
                        <span class="text-[10px] text-gray-500 italic">no period data yet</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- ═══════════ 4-UP KPI STRIP ═══════════ --%>
              <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                  <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                    Realized P&L
                  </p>
                  <p class={[
                    "text-xl sm:text-2xl font-black tabular-nums",
                    realized_total >= 0 && "text-emerald-400",
                    realized_total < 0 && "text-red-400"
                  ]}>
                    {if realized_total >= 0, do: "+", else: "-"}${:erlang.float_to_binary(
                      abs(realized_total),
                      decimals: 2
                    )}
                  </p>
                  <p class="text-[10px] text-gray-600 mt-1">Alpaca + Kalshi settled</p>
                </div>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                  <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                    Unrealized P&L
                  </p>
                  <p class={[
                    "text-xl sm:text-2xl font-black tabular-nums",
                    unrealized_total >= 0 && "text-emerald-400",
                    unrealized_total < 0 && "text-red-400"
                  ]}>
                    {if unrealized_total >= 0, do: "+", else: "-"}${:erlang.float_to_binary(
                      abs(unrealized_total),
                      decimals: 2
                    )}
                  </p>
                  <p class="text-[10px] text-gray-600 mt-1">ForEx mark-to-market</p>
                </div>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                  <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                    Largest Allocation
                  </p>
                  <%= case breakdown.largest do %>
                    <% nil -> %>
                      <p class="text-xl sm:text-2xl font-black tabular-nums text-gray-600">—</p>
                      <p class="text-[10px] text-gray-600 mt-1">No balances loaded</p>
                    <% slice -> %>
                      <p class={["text-xl sm:text-2xl font-black tracking-tight", slice.text_class]}>
                        {slice.label}
                      </p>
                      <p class="text-[10px] text-gray-600 mt-1">
                        {Float.round(slice.percent, 1)}% · ${:erlang.float_to_binary(slice.value,
                          decimals: 2
                        )}
                      </p>
                  <% end %>
                </div>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                  <p class="text-[9px] sm:text-[10px] font-black text-gray-500 uppercase tracking-widest mb-2">
                    Active Brokers
                  </p>
                  <p class="text-xl sm:text-2xl font-black tabular-nums text-white">
                    {Enum.count(breakdown.slices, &(&1.value > 0))}<span class="text-gray-600 font-light">/{length(breakdown.slices)}</span>
                  </p>
                  <p class="text-[10px] text-gray-600 mt-1">Alpaca · Kalshi · Polymarket · ForEx</p>
                </div>
              </div>

              <% diversity_caption = portfolio_diversity_caption(breakdown) %>

              <%!-- ═══════════ DONUT + PER-BROKER CARDS ═══════════ --%>
              <%!-- DonutChart hook wires hover interactivity client-side from
              the data-* attributes below. Server only renders state; hover
              animation never round-trips. --%>
              <%!-- NO `phx-update="ignore"`: broker values stream in async
              after mount (Alpaca/Kalshi/Polymarket/Forex via PubSub), so
              the donut MUST be updatable. DonutChart's `updated/0` callback
               rebinds listeners against the new DOM after every LV patch. --%>
              <div
                id="portfolio-donut-chart"
                phx-hook="DonutChart"
                class="grid grid-cols-1 lg:grid-cols-5 gap-6"
              >
                <%!-- Donut --%>
                <div class="lg:col-span-2 rounded-2xl border border-white/10 bg-white/[0.02] p-6 flex flex-col items-center justify-center">
                  <p class="text-[10px] font-black text-gray-500 uppercase tracking-widest mb-4 self-start">
                    Allocation · Hover to inspect
                  </p>
                  <%= if breakdown.total_value > 0.0 do %>
                    <div class="relative">
                      <%!-- viewBox -60..60 leaves breathing room for the stroke +
                      hover drop-shadow. SVG uses overflow-visible so glow
                      can't be clipped. --%>
                      <svg viewBox="-60 -60 120 120" class="w-72 h-72 -rotate-90 overflow-visible">
                        <circle
                          r="44"
                          cx="0"
                          cy="0"
                          fill="transparent"
                          stroke="rgba(255,255,255,0.04)"
                          stroke-width="14"
                        />
                        <%= for slice <- breakdown.slices, slice.value > 0 do %>
                          <% circumference = 2 * 3.141592653589793 * 44
                          slice_len = circumference * slice.percent / 100
                          gap_len = circumference - slice_len
                          offset = -circumference * slice.cumulative_percent / 100 %>
                          <circle
                            r="44"
                            cx="0"
                            cy="0"
                            fill="transparent"
                            stroke={slice.stroke_color}
                            stroke-width="14"
                            stroke-linecap="butt"
                            stroke-dasharray={"#{Float.round(slice_len, 2)} #{Float.round(gap_len, 2)}"}
                            stroke-dashoffset={Float.round(offset, 2)}
                            class="cursor-pointer transition-all"
                            style="transform-origin: center;"
                            data-arc={Atom.to_string(slice.key)}
                            data-color={slice.stroke_color}
                          />
                        <% end %>
                      </svg>
                      <%!-- Center label — two stable DOM nodes (default + hovered),
                      hook toggles `hidden` class and writes textContent into
                      the hovered spans. CyberSec 9983: textContent only, never
                      innerHTML. --%>
                      <div class="absolute inset-0 flex flex-col items-center justify-center text-center pointer-events-none px-6">
                        <div data-donut-hole-default>
                          <p class="text-[9px] font-black text-gray-500 uppercase tracking-widest">
                            Total Value
                          </p>
                          <p class="text-2xl font-black tabular-nums text-white mt-1">
                            ${:erlang.float_to_binary(breakdown.total_value, decimals: 2)}
                          </p>
                          <p class="text-[10px] text-gray-500 mt-1 italic leading-snug">
                            {diversity_caption}
                          </p>
                        </div>
                        <div data-donut-hole-hovered class="hidden">
                          <p data-hole-label class="text-[9px] uppercase tracking-widest"></p>
                          <p class="text-2xl font-black tabular-nums text-white mt-1">
                            <span class="text-gray-500 font-light">$</span><span data-hole-value></span>
                          </p>
                          <p data-hole-pct class="text-xs font-mono tabular-nums font-bold mt-1"></p>
                          <p class="text-[11px] font-mono tabular-nums mt-0.5">
                            P&L <span data-hole-pnl></span>
                          </p>
                        </div>
                      </div>
                    </div>
                  <% else %>
                    <div class="py-20 text-center">
                      <div class="w-16 h-16 mx-auto rounded-full border border-white/10 bg-white/[0.02] flex items-center justify-center mb-3">
                        <.icon name="hero-chart-pie" class="w-8 h-8 text-gray-600" />
                      </div>
                      <p class="text-xs text-gray-500">No broker balances loaded yet.</p>
                    </div>
                  <% end %>
                </div>

                <%!-- Per-broker cards (color-tinted) — hook reads data-card to wire hover --%>
                <div
                  id="portfolio-broker-cards"
                  phx-hook="FadeInStagger"
                  class="lg:col-span-3 grid grid-cols-1 sm:grid-cols-2 gap-3"
                >
                  <%= for slice <- breakdown.slices do %>
                    <% pnl_sign = if slice.pnl >= 0, do: "+", else: "-"
                    pnl_value = :erlang.float_to_binary(abs(slice.pnl), decimals: 2) %>
                    <div
                      class={[
                        "rounded-2xl border p-5 backdrop-blur-md flex flex-col gap-3 transition-all cursor-pointer",
                        slice.tint_class
                      ]}
                      data-card={Atom.to_string(slice.key)}
                      data-label={slice.label}
                      data-value={:erlang.float_to_binary(slice.value, decimals: 2)}
                      data-pct={Float.round(slice.percent, 1)}
                      data-pnl={"#{pnl_sign}$#{pnl_value}"}
                      data-pnl-sign={pnl_sign}
                      data-color={slice.stroke_color}
                      data-text-class={slice.text_class}
                    >
                      <div class="flex items-start justify-between gap-2">
                        <div class="min-w-0">
                          <div class="flex items-center gap-2">
                            <span
                              class="w-2.5 h-2.5 rounded-full shrink-0"
                              style={"background-color: #{slice.stroke_color}; box-shadow: 0 0 12px #{slice.stroke_color};"}
                            />
                            <h4 class={["text-sm uppercase tracking-widest", slice.text_class]}>
                              {slice.label}
                            </h4>
                          </div>
                          <p class="text-[10px] text-gray-500 mt-1 italic">{slice.subtitle}</p>
                        </div>
                        <%= if slice.loaded? do %>
                          <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full border border-emerald-500/20 bg-emerald-500/5 text-[9px] font-bold text-emerald-400 uppercase tracking-widest">
                            <span class="w-1 h-1 rounded-full bg-emerald-400" /> Live
                          </span>
                        <% else %>
                          <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full border border-white/10 bg-white/[0.02] text-[9px] font-bold text-gray-500 uppercase tracking-widest">
                            Offline
                          </span>
                        <% end %>
                      </div>

                      <p class="text-3xl font-black tabular-nums text-white leading-none flex items-baseline">
                        <span class="text-gray-500 font-light">$</span>
                        <span
                          id={"portfolio-slice-value-#{slice.key}"}
                          phx-hook="CountUp"
                          data-target={slice.value}
                          data-decimals="2"
                        >
                          {:erlang.float_to_binary(slice.value, decimals: 2)}
                        </span>
                      </p>

                      <%!-- Allocation bar --%>
                      <div class="space-y-1.5">
                        <div class="flex items-baseline justify-between text-[10px] font-mono">
                          <span class="text-gray-500 uppercase tracking-widest font-bold">
                            Allocation
                          </span>
                          <span class={["tabular-nums font-bold", slice.text_class]}>
                            {Float.round(slice.percent, 1)}%
                          </span>
                        </div>
                        <div class="h-1.5 rounded-full bg-white/5 overflow-hidden">
                          <div
                            class={[
                              "h-full rounded-full transition-all duration-500",
                              slice.bar_class
                            ]}
                            style={"width: #{Float.round(slice.percent, 2)}%;"}
                          />
                        </div>
                      </div>

                      <div class="flex items-baseline justify-between pt-2 border-t border-white/5">
                        <span class="text-[10px] text-gray-500 uppercase tracking-widest font-bold">
                          P&L
                        </span>
                        <span class={[
                          "text-sm font-mono font-bold tabular-nums",
                          slice.pnl >= 0 && "text-emerald-400",
                          slice.pnl < 0 && "text-red-400"
                        ]}>
                          {if slice.pnl >= 0, do: "+", else: "-"}${:erlang.float_to_binary(
                            abs(slice.pnl),
                            decimals: 2
                          )}
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- Agent Logs Tab --%>
          <%= if @active_tab == :logs do %>
            <div class="px-4 sm:px-6 lg:px-8 py-6 space-y-4">
              <div class="flex items-center justify-between">
                <h2 class="text-xs font-black text-white uppercase tracking-widest">
                  Agent Runtime Log
                </h2>
                <%= if @selected_agent do %>
                  <span class="text-[10px] text-gray-500 uppercase tracking-widest font-mono">
                    {@selected_agent.name} · last 100 events
                  </span>
                <% end %>
              </div>

              <%= if @agent_log_entries == [] do %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                  <p class="text-gray-500 text-sm">No log entries yet.</p>
                  <p class="text-gray-600 text-xs mt-2">
                    Entries appear here as the agent ticks. Try activating the agent if it's paused.
                  </p>
                </div>
              <% else %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-hidden">
                  <div class="divide-y divide-white/5 font-mono text-xs">
                    <%= for entry <- @agent_log_entries do %>
                      <% level_classes =
                        case entry.level do
                          :error -> "text-red-400"
                          :warn -> "text-amber-400"
                          :debug -> "text-gray-600"
                          _ -> "text-gray-300"
                        end %>
                      <div class="flex items-start gap-3 px-4 py-2 hover:bg-white/[0.02]">
                        <span class="text-gray-600 shrink-0 tabular-nums">
                          {Calendar.strftime(entry.ts, "%H:%M:%S")}
                        </span>
                        <span class={[
                          "shrink-0 uppercase text-[9px] font-black w-10 text-right",
                          level_classes
                        ]}>
                          {entry.level}
                        </span>
                        <span class="text-indigo-400 shrink-0 text-[10px]">
                          [{entry.event}]
                        </span>
                        <span class={["flex-1 break-words", level_classes]}>
                          {entry.message}
                        </span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>

      <%!-- Agent Context Modal --%>
      <%= if @show_agent_context do %>
        <div
          class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm"
          phx-click="close_agent_context"
        >
          <div
            class="relative w-full max-w-3xl max-h-[80vh] mx-4 rounded-2xl border border-white/10 bg-[#0a0a0f] shadow-2xl overflow-hidden"
            phx-click-away="close_agent_context"
          >
            <div class="flex items-center justify-between px-6 py-4 border-b border-white/10">
              <h2 class="text-xs font-black text-white uppercase tracking-widest">
                Agent Context — Copy to Claude/GPT
              </h2>
              <button
                phx-click="close_agent_context"
                class="text-gray-500 hover:text-white transition-colors"
              >
                <.icon name="hero-x-mark" class="w-5 h-5" />
              </button>
            </div>

            <div class="p-6 overflow-y-auto max-h-[60vh] space-y-6">
              <%!-- ── Setup section — read this BEFORE pasting the prompt ── --%>
              <div class="rounded-xl border border-yellow-500/30 bg-yellow-500/[0.04] p-5 space-y-3">
                <div class="flex items-center gap-2">
                  <span class="text-yellow-300 text-base">⚙️</span>
                  <h3 class="text-xs font-black text-yellow-200 uppercase tracking-widest">
                    First-time setup (one minute, then never again)
                  </h3>
                </div>
                <p class="text-[11px] text-gray-300 leading-relaxed">
                  Recent versions of <strong>Codex CLI</strong>
                  and <strong>Claude Code</strong>
                  default their sandbox to deny outbound network. Without this step the agent
                  cannot reach
                  <code class="px-1 py-0.5 rounded bg-white/[0.08] text-white">
                    kite-agent-hub.fly.dev
                  </code>
                  — you will see a "Could not resolve host" error. Pick your runtime:
                </p>

                <div class="space-y-3">
                  <details class="rounded-lg border border-white/10 bg-black/30">
                    <summary class="cursor-pointer px-4 py-2.5 text-[11px] font-bold text-white uppercase tracking-widest hover:bg-white/[0.04]">
                      Codex CLI
                    </summary>
                    <div class="px-4 pb-3 pt-1 space-y-2 text-[11px] text-gray-300">
                      <p>One-shot per session:</p>
                      <pre class="text-[10px] font-mono bg-black/60 rounded p-2 border border-white/5 text-emerald-300">codex -s workspace-write -c sandbox_workspace_write.network_access=true</pre>
                      <p>
                        Or persistent (recommended) — add to <code class="bg-white/[0.06] px-1 rounded">~/.codex/config.toml</code>:
                      </p>
                      <pre class="text-[10px] font-mono bg-black/60 rounded p-2 border border-white/5 text-emerald-300">sandbox_mode = "workspace-write"

    [sandbox_workspace_write]
    network_access = true</pre>
                    </div>
                  </details>

                  <details class="rounded-lg border border-white/10 bg-black/30">
                    <summary class="cursor-pointer px-4 py-2.5 text-[11px] font-bold text-white uppercase tracking-widest hover:bg-white/[0.04]">
                      Claude Code
                    </summary>
                    <div class="px-4 pb-3 pt-1 space-y-2 text-[11px] text-gray-300">
                      <p>
                        In-session: type
                        <code class="bg-white/[0.06] px-1 rounded">/permissions</code>
                        and add:
                      </p>
                      <pre class="text-[10px] font-mono bg-black/60 rounded p-2 border border-white/5 text-emerald-300">WebFetch(domain:kite-agent-hub.fly.dev)
    Bash(curl:*kite-agent-hub.fly.dev*)</pre>
                      <p>
                        Or persistent — in <code class="bg-white/[0.06] px-1 rounded">.claude/settings.json</code>:
                      </p>
                      <pre class="text-[10px] font-mono bg-black/60 rounded p-2 border border-white/5 text-emerald-300">{claude_settings_snippet()}</pre>
                    </div>
                  </details>

                  <details class="rounded-lg border border-white/10 bg-black/30">
                    <summary class="cursor-pointer px-4 py-2.5 text-[11px] font-bold text-white uppercase tracking-widest hover:bg-white/[0.04]">
                      Direct Anthropic SDK / your own script
                    </summary>
                    <div class="px-4 pb-3 pt-1 space-y-2 text-[11px] text-gray-300">
                      <p>
                        No sandbox to configure — should work as-is. If your script still cannot reach KAH, check your local firewall / VPN / proxy.
                      </p>
                    </div>
                  </details>
                </div>

                <p class="text-[10px] text-gray-500 leading-relaxed">
                  Quick verify (run in a regular terminal — bypasses any sandbox):
                  <code class="block mt-1 px-2 py-1.5 rounded bg-black/60 border border-white/5 font-mono text-[10px] text-emerald-300 break-all">
                    curl -sS -H "Authorization: Bearer YOUR_TOKEN" https://kite-agent-hub.fly.dev/api/v1/agents/me
                  </code>
                </p>
              </div>

              <%!-- ── The actual agent prompt ── --%>
              <div class="space-y-2">
                <p class="text-[10px] text-gray-500 uppercase tracking-widest font-bold">
                  Agent prompt — paste into your LLM after sandbox is configured
                </p>
                <pre class="text-xs text-gray-300 font-mono whitespace-pre-wrap leading-relaxed bg-black/40 rounded-xl p-4 border border-white/5">{@agent_context_text}</pre>
              </div>

              <%!-- ── Recent news for agent's open positions ── --%>
              <%= if @agent_context_news != [] do %>
                <div class="space-y-2">
                  <p class="text-[10px] text-gray-500 uppercase tracking-widest font-bold">
                    Recent headlines for open positions
                  </p>
                  <p class="text-[10px] text-amber-400/80">
                    Display only — these headlines are not yet injected into the LLM prompt.
                  </p>
                  <ul class="space-y-2">
                    <li
                      :for={item <- @agent_context_news}
                      class="bg-black/40 rounded-xl p-3 border border-white/5"
                    >
                      <p class="text-xs text-white font-medium leading-snug">
                        {item.headline}
                      </p>
                      <p
                        :if={item.summary && item.summary != ""}
                        class="text-[11px] text-gray-400 mt-1 leading-snug"
                      >
                        {item.summary}
                      </p>
                      <p class="text-[10px] text-gray-600 mt-1">
                        {if item.created_at, do: item.created_at, else: ""}
                        <%= if item.symbols != [] do %>
                          · {Enum.join(item.symbols, ", ")}
                        <% end %>
                      </p>
                    </li>
                  </ul>
                </div>
              <% end %>
            </div>
            <div class="px-6 py-4 border-t border-white/10 flex items-center justify-between">
              <p class="text-[10px] text-gray-600 uppercase tracking-widest">
                Paste into Claude Code, ChatGPT, or any LLM
              </p>
              <button
                id="copy-context-btn"
                phx-hook="CopyToClipboard"
                data-text={@agent_context_text}
                class="inline-flex items-center gap-2 px-4 py-2 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-black text-xs uppercase tracking-widest transition-colors"
              >
                <.icon name="hero-clipboard-document" class="w-4 h-4" /> Copy to Clipboard
              </button>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Chat Popup --%>
      <%= if @organization do %>
        <.live_component
          module={KiteAgentHubWeb.ChatComponent}
          id="chat-popup"
          org_id={@organization.id}
          user={@current_scope.user}
          agent={@selected_agent}
          agents={@agents}
          messages={@chat_messages}
        />
      <% end %>
    </Layouts.app>
    """
  end

  # ── Chat PubSub handler ─────────────────────────────────────────────────────

  def handle_info({:chat_message, message}, socket) do
    org = socket.assigns[:organization]

    # Authorization check: only append the broadcast payload if it
    # belongs to the viewer's org. This prevents a cross-org leak in
    # the event a process is ever subscribed to more than one topic.
    if org && message.organization_id == org.id do
      messages =
        (socket.assigns[:chat_messages] || [])
        |> Kernel.++([sanitize_broadcast(message)])
        |> Enum.take(-50)

      {:noreply, assign(socket, :chat_messages, messages)}
    else
      {:noreply, socket}
    end
  end

  # ── Agent log real-time feed ────────────────────────────────────────────────────

  def handle_info({:agent_log_entry, entry}, socket) do
    # Prepend newest entry; keep assigns list bounded to 100.
    entries = [entry | socket.assigns.agent_log_entries] |> Enum.take(100)
    {:noreply, assign(socket, :agent_log_entries, entries)}
  end

  # Live trade tick from AlpacaStream. Update the per-symbol live price
  # map; the Alpaca tab template overlays this onto the static
  # current_price column when present.
  def handle_info(%{type: "t", symbol: sym, price: price}, socket)
      when is_binary(sym) and is_number(price) do
    prices = Map.put(socket.assigns[:alpaca_live_tick_prices] || %{}, sym, price)

    # First tick that arrives flips status from :connecting → :live.
    status =
      case socket.assigns[:alpaca_live_tick_status] do
        :live -> :live
        _ -> :live
      end

    {:noreply,
     socket
     |> assign(:alpaca_live_tick_prices, prices)
     |> assign(:alpaca_live_tick_status, status)}
  end

  # Other tick types (quotes, bars) ignored for now — could overlay
  # bid/ask later if we add columns for it.
  def handle_info(%{type: t}, socket) when t in ["q", "b", "n"] do
    {:noreply, socket}
  end

  # Safety net: an unmatched handle_info or handle_event crashes the LV
  # process silently (no log) and Phoenix surfaces "something went wrong"
  # to the user. These catch-all clauses MUST stay last — Elixir matches
  # top-to-bottom, so any specific clause declared above remains the
  # preferred dispatch target. If you add a new specific clause below
  # this line it will be unreachable.
  def handle_info(msg, socket) do
    Logger.warning("DashboardLive: unhandled handle_info #{inspect(msg)}")
    {:noreply, socket}
  end

  # ── Kalshi order management ────────────────────────────────────────────────────

  @doc false
  def handle_event("cancel_kalshi_order", %{"order_id" => order_id}, socket) do
    require Logger
    org = socket.assigns.organization

    result =
      with org when not is_nil(org) <- org,
           {:ok, credentials} <- credentials_module().fetch_secret_with_env(org.id, :kalshi),
           {key_id, pem, env} <- credentials,
           {:ok, outcome} <- KalshiClient.cancel_order(key_id, pem, order_id, env) do
        {:ok, outcome}
      else
        nil -> {:error, :no_org}
        err -> err
      end

    socket =
      case result do
        {:ok, :cancelled} ->
          Logger.info("DashboardLive: cancelled Kalshi order #{order_id}")
          # Reload the Kalshi tab so the pending_orders list refreshes.
          send(self(), :load_kalshi)
          put_flash(socket, :info, "Order #{String.slice(order_id, 0, 8)}… cancelled.")

        {:ok, :already_terminal} ->
          send(self(), :load_kalshi)
          put_flash(socket, :info, "Order already filled or cancelled — refreshing.")

        {:error, reason} ->
          Logger.warning(
            "DashboardLive: cancel_kalshi_order failed for #{order_id}: #{inspect(reason)}"
          )

          put_flash(socket, :error, "Cancel failed: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  def handle_event(event, params, socket) do
    Logger.warning("DashboardLive: unhandled handle_event #{inspect(event)} #{inspect(params)}")

    {:noreply, socket}
  end

  # Strip the persisted row down to the fields the chat UI actually
  # renders. The real ChatMessage struct has no credential fields, but
  # trimming here enforces the CyberSec contract that PubSub payloads
  # never carry tokens, keys, or owner metadata — even if the schema
  # grows later.
  defp sanitize_broadcast(message) do
    %{
      id: message.id,
      text: message.text,
      sender_type: message.sender_type,
      sender_name: message.sender_name,
      kite_agent_id: Map.get(message, :kite_agent_id),
      inserted_at: message.inserted_at
    }
  end

  # ── SVG sparkline helper ───────────────────────────────────────────────────────

  defp sparkline_points(history, width, height) when length(history) > 1 do
    values = Enum.map(history, & &1.v)
    min_v = Enum.min(values)
    max_v = Enum.max(values)
    range = max(max_v - min_v, 0.01)
    count = length(history) - 1

    history
    |> Enum.with_index()
    |> Enum.map(fn {%{v: v}, i} ->
      x = i / count * width
      y = height - (v - min_v) / range * height
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp sparkline_points(_, _, _), do: ""

  # Rich chart data for the forex instrument price chart. Builds the
  # main line points, gradient-area polygon, 20-period MA overlay,
  # Y-axis tick metadata, X-axis time labels, and a crosshair-points
  # payload (JSON-encoded) — all server-side so the `CrosshairChart`
  # hook reads from a server-trusted `data-points` attr instead of
  # parsing formatted DOM text (CyberSec 13769).
  defp forex_instrument_chart_data(candles, price_code, width, height)
       when is_list(candles) and candles != [] do
    sub_key =
      case price_code do
        "B" -> "bid"
        "A" -> "ask"
        _ -> "mid"
      end

    parsed =
      candles
      |> Enum.map(fn c ->
        close =
          case get_in(c, [sub_key, "c"]) || get_in(c, ["mid", "c"]) do
            s when is_binary(s) ->
              case Float.parse(s) do
                {f, _} -> f
                :error -> nil
              end

            n when is_number(n) ->
              n * 1.0

            _ ->
              nil
          end

        if is_number(close), do: %{close: close, time: Map.get(c, "time")}, else: nil
      end)
      |> Enum.reject(&is_nil/1)

    if length(parsed) < 2 do
      :empty
    else
      closes = Enum.map(parsed, & &1.close)
      min_v = Enum.min(closes)
      max_v = Enum.max(closes)
      raw_range = max_v - min_v
      range = if raw_range == 0.0, do: 0.0001, else: raw_range
      last_idx = length(parsed) - 1
      pad_y = 6.0
      inner_h = height - 2 * pad_y

      to_xy = fn v, i ->
        x = i / last_idx * width
        y = height - pad_y - (v - min_v) / range * inner_h
        {Float.round(x, 2), Float.round(y, 2)}
      end

      pts =
        closes
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> to_xy.(v, i) end)

      path_d = catmull_rom_path(pts)

      area_d =
        "#{path_d} L #{Float.round(width * 1.0, 2)} #{Float.round(height * 1.0, 2)} L 0 #{Float.round(height * 1.0, 2)} Z"

      ma_window = 20

      ma_path_d =
        if length(closes) >= ma_window do
          ma_pts =
            closes
            |> Enum.with_index()
            |> Enum.map(fn {_v, i} ->
              if i < ma_window - 1 do
                nil
              else
                window = Enum.slice(closes, i - ma_window + 1, ma_window)
                avg = Enum.sum(window) / ma_window
                to_xy.(avg, i)
              end
            end)
            |> Enum.reject(&is_nil/1)

          catmull_rom_path(ma_pts)
        else
          ""
        end

      # Use 5 decimals for FX-style pairs (sub-100), 3 for crosses or
      # commodities above 100 (USD_JPY, XAU_USD, etc.).
      decimals = if max_v >= 100, do: 3, else: 5

      y_ticks =
        for q <- [0.0, 0.25, 0.5, 0.75, 1.0] do
          val = max_v - q * raw_range
          y = pad_y + q * inner_h

          %{
            y: Float.round(y, 2),
            label: :erlang.float_to_binary(val, decimals: decimals)
          }
        end

      first_label = parse_oanda_time(List.first(parsed).time)
      mid_label = parse_oanda_time(Enum.at(parsed, div(last_idx, 2)).time)
      last_label = parse_oanda_time(List.last(parsed).time)

      x_ticks = [
        %{label: first_label},
        %{label: mid_label},
        %{label: last_label}
      ]

      crosshair_points =
        parsed
        |> Enum.with_index()
        |> Enum.map(fn {%{close: c, time: t}, i} ->
          {x, y} = to_xy.(c, i)

          %{
            x: x,
            y: y,
            v: :erlang.float_to_binary(c, decimals: decimals),
            t: parse_oanda_time(t)
          }
        end)

      first_v = List.first(closes)
      last_v = List.last(closes)
      delta = last_v - first_v
      delta_pct = if first_v > 0.0, do: delta / first_v * 100.0, else: 0.0

      %{
        path_d: path_d,
        area_d: area_d,
        ma_path_d: ma_path_d,
        y_ticks: y_ticks,
        x_ticks: x_ticks,
        crosshair_data: Jason.encode!(crosshair_points),
        first: first_v,
        last: last_v,
        min: min_v,
        max: max_v,
        delta: delta,
        delta_pct: delta_pct,
        decimals: decimals
      }
    end
  rescue
    _ -> :empty
  end

  defp forex_instrument_chart_data(_, _, _, _), do: :empty

  # Catmull-Rom-to-cubic-bezier interpolation. Takes a list of {x, y}
  # tuples and returns an SVG path-d string in the form
  # `M x0 y0 C cp1x cp1y, cp2x cp2y, x1 y1 C ...`. The first segment
  # uses P0 = P1 (no left neighbor) and the last uses Pn+1 = Pn (no
  # right neighbor), so endpoints don't flick off. Tension is fixed
  # at the standard 1/6 weight — anything tighter and the curve
  # over-shoots local extremes, anything looser and it looks like a
  # polyline again.
  defp catmull_rom_path(pts) when is_list(pts) and length(pts) >= 2 do
    arr = pts
    {x0, y0} = List.first(arr)
    count = length(arr)

    segments =
      for i <- 1..(count - 1) do
        {xm, ym} = Enum.at(arr, max(i - 2, 0))
        {x1, y1} = Enum.at(arr, i - 1)
        {x2, y2} = Enum.at(arr, i)
        {xn, yn} = Enum.at(arr, min(i + 1, count - 1))

        c1x = x1 + (x2 - xm) / 6
        c1y = y1 + (y2 - ym) / 6
        c2x = x2 - (xn - x1) / 6
        c2y = y2 - (yn - y1) / 6

        "C #{Float.round(c1x, 2)} #{Float.round(c1y, 2)}, #{Float.round(c2x, 2)} #{Float.round(c2y, 2)}, #{Float.round(x2, 2)} #{Float.round(y2, 2)}"
      end

    "M #{x0} #{y0} " <> Enum.join(segments, " ")
  end

  defp catmull_rom_path(_), do: ""

  # Same trading-chart treatment for the Alpaca portfolio equity series.
  # Input is the LV assign `@alpaca_history` — a list of `%{t: unix_ts,
  # v: equity_float}` rows pulled by `AlpacaClient.portfolio_history/5`.
  # Returns the same map shape as `forex_instrument_chart_data/4` so the
  # template + `CrosshairChart` hook can render it identically. Equity
  # is in dollars so labels are formatted with 2 decimals; tooltip
  # values include the `$` symbol baked into the value string.
  defp alpaca_equity_chart_data(history, width, height)
       when is_list(history) and length(history) > 1 do
    parsed =
      history
      |> Enum.map(fn row ->
        v = Map.get(row, :v)
        t = Map.get(row, :t)

        cond do
          is_number(v) -> %{v: v * 1.0, t: t}
          true -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    if length(parsed) < 2 do
      :empty
    else
      values = Enum.map(parsed, & &1.v)
      min_v = Enum.min(values)
      max_v = Enum.max(values)
      raw_range = max_v - min_v
      # Flat-series fallback — see session_nav_chart_data/3 for context.
      flat? = raw_range == 0.0
      display_range = if flat?, do: max(max_v * 0.002, 0.02), else: raw_range
      display_min = if flat?, do: max_v - display_range / 2, else: min_v
      display_max = if flat?, do: max_v + display_range / 2, else: max_v
      last_idx = length(parsed) - 1
      pad_y = 6.0
      inner_h = height - 2 * pad_y

      to_xy = fn v, i ->
        x = i / last_idx * width
        y = height - pad_y - (v - display_min) / display_range * inner_h
        {Float.round(x, 2), Float.round(y, 2)}
      end

      pts =
        values
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> to_xy.(v, i) end)

      path_d = catmull_rom_path(pts)

      area_d =
        "#{path_d} L #{Float.round(width * 1.0, 2)} #{Float.round(height * 1.0, 2)} L 0 #{Float.round(height * 1.0, 2)} Z"

      y_ticks =
        for q <- [0.0, 0.25, 0.5, 0.75, 1.0] do
          val = display_max - q * display_range
          y = pad_y + q * inner_h

          %{
            y: Float.round(y, 2),
            label: :erlang.float_to_binary(val, decimals: 0)
          }
        end

      first_label = format_alpaca_ts(List.first(parsed).t)
      mid_label = format_alpaca_ts(Enum.at(parsed, div(last_idx, 2)).t)
      last_label = format_alpaca_ts(List.last(parsed).t)

      x_ticks = [
        %{label: first_label},
        %{label: mid_label},
        %{label: last_label}
      ]

      crosshair_points =
        parsed
        |> Enum.with_index()
        |> Enum.map(fn {%{v: v, t: t}, i} ->
          {x, y} = to_xy.(v, i)

          %{
            x: x,
            y: y,
            v: "$" <> :erlang.float_to_binary(v, decimals: 2),
            t: format_alpaca_ts(t)
          }
        end)

      first_v = List.first(values)
      last_v = List.last(values)
      delta = last_v - first_v
      delta_pct = if first_v > 0.0, do: delta / first_v * 100.0, else: 0.0

      %{
        path_d: path_d,
        area_d: area_d,
        y_ticks: y_ticks,
        x_ticks: x_ticks,
        crosshair_data: Jason.encode!(crosshair_points),
        first: first_v,
        last: last_v,
        min: min_v,
        max: max_v,
        delta: delta,
        delta_pct: delta_pct
      }
    end
  rescue
    _ -> :empty
  end

  defp alpaca_equity_chart_data(_, _, _), do: :empty

  # Same trading-chart treatment for the Forex Session NAV ring buffer
  # (`@forex_nav_history` — most-recent-first list of {unix_ts, nav}
  # tuples appended every 30s by the forex poll). Returns the same
  # shape as the other chart helpers so the template + CrosshairChart
  # hook can render it identically. (Phorari 13815 — Session NAV
  # chart was scoped weeks ago but never built; this is that PR.)
  defp session_nav_chart_data(history, width, height)
       when is_list(history) and length(history) > 1 do
    # @forex_nav_history is reverse-chronological; flip to oldest -> newest
    # so the bezier reads left-to-right.
    ordered = Enum.reverse(history)

    parsed =
      Enum.map(ordered, fn
        {ts, nav} when is_integer(ts) and is_number(nav) -> %{v: nav * 1.0, t: ts}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if length(parsed) < 2 do
      :empty
    else
      values = Enum.map(parsed, & &1.v)
      min_v = Enum.min(values)
      max_v = Enum.max(values)
      raw_range = max_v - min_v
      # When NAV hasn't moved at all (Mico 13836 — flat series shows
      # all 5 Y-axis labels at the same number and the line hugs the
      # bottom), synthesize a small ±0.1% window around the value so
      # the chart centers the flat line and the axis ticks show a
      # plausible range. The path scales against `display_min` /
      # `display_range`, so the synthetic window is purely visual.
      flat? = raw_range == 0.0
      display_range = if flat?, do: max(max_v * 0.002, 0.02), else: raw_range
      display_min = if flat?, do: max_v - display_range / 2, else: min_v
      display_max = if flat?, do: max_v + display_range / 2, else: max_v
      last_idx = length(parsed) - 1
      pad_y = 6.0
      inner_h = height - 2 * pad_y

      to_xy = fn v, i ->
        x = i / last_idx * width
        y = height - pad_y - (v - display_min) / display_range * inner_h
        {Float.round(x, 2), Float.round(y, 2)}
      end

      pts =
        values
        |> Enum.with_index()
        |> Enum.map(fn {v, i} -> to_xy.(v, i) end)

      path_d = catmull_rom_path(pts)

      area_d =
        "#{path_d} L #{Float.round(width * 1.0, 2)} #{Float.round(height * 1.0, 2)} L 0 #{Float.round(height * 1.0, 2)} Z"

      y_ticks =
        for q <- [0.0, 0.25, 0.5, 0.75, 1.0] do
          val = display_max - q * display_range
          y = pad_y + q * inner_h

          %{
            y: Float.round(y, 2),
            label: :erlang.float_to_binary(val, decimals: 2)
          }
        end

      first_label = format_session_time(List.first(parsed).t)
      mid_label = format_session_time(Enum.at(parsed, div(last_idx, 2)).t)
      last_label = format_session_time(List.last(parsed).t)

      x_ticks = [
        %{label: first_label},
        %{label: mid_label},
        %{label: last_label}
      ]

      crosshair_points =
        parsed
        |> Enum.with_index()
        |> Enum.map(fn {%{v: v, t: t}, i} ->
          {x, y} = to_xy.(v, i)

          %{
            x: x,
            y: y,
            v: "$" <> :erlang.float_to_binary(v, decimals: 2),
            t: format_session_time(t)
          }
        end)

      first_v = List.first(values)
      last_v = List.last(values)
      delta = last_v - first_v
      delta_pct = if first_v > 0.0, do: delta / first_v * 100.0, else: 0.0

      %{
        path_d: path_d,
        area_d: area_d,
        y_ticks: y_ticks,
        x_ticks: x_ticks,
        crosshair_data: Jason.encode!(crosshair_points),
        first: first_v,
        last: last_v,
        min: min_v,
        max: max_v,
        delta: delta,
        delta_pct: delta_pct
      }
    end
  rescue
    _ -> :empty
  end

  defp session_nav_chart_data(_, _, _), do: :empty

  # Alpaca's portfolio_history endpoint returns Unix-second timestamps.
  # For intraday periods this should read as a time-of-day; for daily
  # periods (1W / 1M / etc.) a M/D date reads better. We render both
  # so the label always has context.
  defp format_alpaca_ts(ts) when is_integer(ts) do
    case DateTime.from_unix(ts) do
      {:ok, dt} ->
        "#{pad2(dt.month)}/#{pad2(dt.day)} #{pad2(dt.hour)}:#{pad2(dt.minute)}"

      _ ->
        "—"
    end
  rescue
    _ -> "—"
  end

  defp format_alpaca_ts(_), do: "—"

  defp parse_oanda_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> "#{pad2(dt.hour)}:#{pad2(dt.minute)}"
      _ -> "—"
    end
  rescue
    _ -> "—"
  end

  defp parse_oanda_time(_), do: "—"

  defp pad2(n) when is_integer(n) and n >= 0 and n < 10, do: "0#{n}"
  defp pad2(n) when is_integer(n), do: "#{n}"
  defp pad2(_), do: "00"

  # Cumulative net Kalshi P&L curve. `settlements` come from
  # `KalshiClient.settlements/4` with `:revenue` (gross payout) and
  # `:fees` already converted to dollars by `parse_settlement/1`.
  # Net per settlement = `revenue - fees`; we accumulate
  # chronologically (sorted ascending by `:settled_time`) so the line
  # rises when the agent wins and falls when it loses, ending at the
  # same `total_settled_pnl` shown in the summary card. Empty input
  # returns "" so the caller can fall back to its empty-state copy.
  defp kalshi_pnl_sparkline(settlements, width, height) when length(settlements) > 1 do
    # Drop settlements without a `settled_time` so `Enum.sort_by/2`
    # never compares nil keys (raises). Same defensive shape as the
    # `kalshi_pnl_zero_y/2` fix in this PR.
    sorted =
      settlements
      |> Enum.reject(&is_nil(&1.settled_time))
      |> Enum.sort_by(& &1.settled_time)

    values =
      sorted
      |> Enum.scan(0.0, fn s, acc -> acc + (s.revenue - s.fees) end)

    case values do
      list when length(list) < 2 ->
        ""

      _ ->
        min_v = Enum.min(values)
        max_v = Enum.max(values)
        range = max(max_v - min_v, 0.01)
        count = length(values) - 1

        # Scale the y-axis around `min_v` so a positive final value
        # rises toward y=0 and a negative final value collapses
        # toward y=height — same orientation as the Alpaca / forex
        # sparklines.
        values
        |> Enum.with_index()
        |> Enum.map(fn {v, i} ->
          x = i / count * width * 1.0
          y = height - (v - min_v) / range * height
          "#{Float.round(x, 1)},#{Float.round(y, 1)}"
        end)
        |> Enum.join(" ")
    end
  end

  defp kalshi_pnl_sparkline(_, _, _), do: ""

  # Y-coordinate of the break-even (P&L = 0) horizontal reference
  # line, computed against the same `(min_v, max_v, range)` scale
  # `kalshi_pnl_sparkline/3` uses. When the entire curve is positive,
  # the zero line sits at the bottom of the chart; when entirely
  # negative, at the top; otherwise somewhere in between.
  defp kalshi_pnl_zero_y(settlements, height) when length(settlements) > 1 do
    # `Enum.sort_by/2` crashes on nil sort keys; filter first so a
    # legacy settlement with a missing `settled_time` doesn't take
    # the whole LiveView mount down. `Float.round/2` also requires
    # a float — every branch below explicitly multiplies by 1.0 so
    # the pipe never receives an integer (KAH P1 2026-05-07: v457
    # mount-loop because `min_v >= 0` returned the integer
    # `height` and `Float.round(150, 1)` raised).
    sorted =
      settlements
      |> Enum.reject(&is_nil(&1.settled_time))
      |> Enum.sort_by(& &1.settled_time)

    values =
      sorted
      |> Enum.scan(0.0, fn s, acc -> acc + (s.revenue - s.fees) end)

    case values do
      [] ->
        height * 1.0

      _ ->
        min_v = Enum.min(values)
        max_v = Enum.max(values)
        range = max(max_v - min_v, 0.01)

        zero_y =
          cond do
            min_v >= 0 -> height * 1.0
            max_v <= 0 -> 0.0
            true -> height - (0.0 - min_v) / range * height
          end

        Float.round(zero_y, 1)
    end
  end

  defp kalshi_pnl_zero_y(_, height), do: height * 1.0

  # Cross-broker portfolio breakdown. Reads each broker's loaded
  # data shape from the existing assigns (no new API calls — the
  # per-broker tabs already populated these via their own
  # `Repo.with_user`-scoped loads). Returns a struct with:
  #   * `slices` — one row per broker (Alpaca / Kalshi / ForEx),
  #     including stroke color, value, allocation %, cumulative %
  #     for SVG dash offsets, and a small subtitle line.
  #   * `total_value` — sum of all broker values in dollars.
  #   * `combined_pnl` — realized (Alpaca) + settled (Kalshi). ForEx
  #     P&L is provider-shape-dependent; the ForEx tab handles it.
  #   * `largest` — slice with the biggest allocation, or nil if no
  #     broker has loaded yet.
  #   * `loaded_count` — how many brokers contributed a real value
  #     (used in the header to avoid showing 0/3 when slices are
  #     just empty).
  #
  # Color values match the dashboard's existing per-broker palette:
  #   * Kalshi     — emerald (#22c55e)  — green per Mico's spec (msg 8608).
  #   * Alpaca     — amber (#f59e0b)    — yellow per spec.
  #   * ForEx      — orange (#f97316)   — orange per spec.
  #   * Polymarket — blue   (#3b82f6)   — blue per Mico 9931.
  defp portfolio_breakdown(
         alpaca_data,
         kalshi_data,
         forex_account,
         polymarket_positions,
         pnl_stats
       ) do
    raw_slices = [
      %{
        key: :alpaca,
        label: "Alpaca",
        stroke_color: "#f59e0b",
        text_class: "text-amber-400",
        tint_class:
          "border-amber-500/30 bg-amber-500/[0.04] shadow-[0_0_24px_rgba(245,158,11,0.12)]",
        bar_class: "bg-amber-400",
        value: alpaca_value(alpaca_data),
        loaded?: alpaca_loaded?(alpaca_data),
        pnl: alpaca_pnl(pnl_stats, alpaca_data),
        subtitle: "Equities + options"
      },
      %{
        key: :kalshi,
        label: "Kalshi",
        stroke_color: "#22c55e",
        text_class: "text-emerald-400",
        tint_class:
          "border-emerald-500/30 bg-emerald-500/[0.04] shadow-[0_0_24px_rgba(34,197,94,0.12)]",
        bar_class: "bg-emerald-400",
        value: kalshi_value(kalshi_data),
        loaded?: kalshi_loaded?(kalshi_data),
        pnl: kalshi_settled_pnl(kalshi_data),
        subtitle: "Prediction markets"
      },
      %{
        key: :polymarket,
        label: "Polymarket",
        stroke_color: "#3b82f6",
        text_class: "text-blue-400",
        tint_class:
          "border-blue-500/30 bg-blue-500/[0.04] shadow-[0_0_24px_rgba(59,130,246,0.12)]",
        bar_class: "bg-blue-400",
        value: polymarket_value(polymarket_positions),
        loaded?: polymarket_loaded?(polymarket_positions),
        pnl: polymarket_pnl(polymarket_positions),
        subtitle: "Prediction markets"
      },
      %{
        key: :forex,
        label: "ForEx",
        stroke_color: "#f97316",
        text_class: "text-orange-400",
        tint_class:
          "border-orange-500/30 bg-orange-500/[0.04] shadow-[0_0_24px_rgba(249,115,22,0.12)]",
        bar_class: "bg-orange-400",
        value: forex_value(forex_account),
        loaded?: forex_loaded?(forex_account),
        pnl: forex_unrealized_pnl(forex_account),
        subtitle: "OANDA practice"
      }
    ]

    total_value = Enum.reduce(raw_slices, 0.0, fn s, acc -> acc + s.value end)
    loaded_count = Enum.count(raw_slices, & &1.loaded?)

    {slices, _} =
      Enum.map_reduce(raw_slices, 0.0, fn slice, cum_pct ->
        pct = if total_value > 0.0, do: slice.value / total_value * 100.0, else: 0.0

        slice_with_pct =
          slice
          |> Map.put(:percent, pct)
          |> Map.put(:cumulative_percent, cum_pct)

        {slice_with_pct, cum_pct + pct}
      end)

    largest =
      slices
      |> Enum.filter(&(&1.value > 0))
      |> Enum.max_by(& &1.value, fn -> nil end)

    # Combined P&L per Mico's spec: must reflect ALL connected
    # platforms. Sum is provider-defined per slice — Alpaca takes
    # the BrokerStats live realized number when available (Decimal
    # type from `Trading.BrokerStats.live_stats/1`, already
    # Alpaca-side authoritative); Kalshi reuses
    # `data.total_settled_pnl` from `load_kalshi_data/1`; ForEx
    # uses OANDA's `unrealizedPL` field (mark-to-market on open
    # positions, which is the only OANDA-side number available
    # without extra calls). All three coerced to float here so
    # the headline never hits the `Float.round`/`float_to_binary`
    # crash class from #327.
    combined_pnl = Enum.reduce(raw_slices, 0.0, fn slice, acc -> acc + slice.pnl end)

    %{
      slices: slices,
      total_value: total_value,
      combined_pnl: combined_pnl,
      largest: largest,
      loaded_count: loaded_count
    }
  end

  # ── Per-broker value extraction helpers ─────────────────────────
  # Each helper returns `0.0` when the broker hasn't loaded or the
  # shape is unexpected, so the breakdown total never crashes. The
  # `_loaded?/1` siblings let the UI distinguish "no broker
  # connected" from "broker loaded with $0 balance".

  defp alpaca_value(%{account: %{portfolio_value: pv}}) when is_number(pv), do: pv * 1.0
  defp alpaca_value(_), do: 0.0

  defp alpaca_loaded?(%{account: _}), do: true
  defp alpaca_loaded?(_), do: false

  # Alpaca-side P&L. Prefer the live `Trading.BrokerStats` number
  # — it queries Alpaca directly for FIFO realized P&L on closed
  # orders and is the source of truth the dashboard already uses
  # for `agent_pnl_stats`. `pnl_stats.total_pnl` is a `Decimal`
  # (Alpaca + Kalshi combined per BrokerStats.merge/2), so we
  # subtract Kalshi'"'"'s settled side here to get Alpaca-only and
  # add Kalshi back in its own slice. Falls back to the
  # `account.realized_pnl` shape when broker_stats hasn'"'"'t loaded.
  defp alpaca_pnl(%{total_pnl: %Decimal{} = total_pnl}, kalshi_data) do
    kalshi = kalshi_settled_pnl(kalshi_data)
    Decimal.to_float(total_pnl) - kalshi
  end

  defp alpaca_pnl(_, alpaca_data), do: alpaca_realized_pnl(alpaca_data)

  defp alpaca_realized_pnl(%{account: %{realized_pnl: pnl}}) when is_number(pnl), do: pnl * 1.0
  defp alpaca_realized_pnl(_), do: 0.0

  defp kalshi_value(%{portfolio_value: pv}) when is_number(pv), do: pv * 1.0
  defp kalshi_value(%{balance: %{available_balance: bal}}) when is_number(bal), do: bal * 1.0
  defp kalshi_value(_), do: 0.0

  defp kalshi_loaded?(%{balance: _}), do: true
  defp kalshi_loaded?(_), do: false

  defp kalshi_settled_pnl(%{total_settled_pnl: pnl}) when is_number(pnl), do: pnl * 1.0
  defp kalshi_settled_pnl(_), do: 0.0

  # OANDA's `account` map varies by API version. Try the common
  # shapes; default to 0 when nothing matches. NAV is preferred over
  # balance because it includes unrealized P&L, but either works as
  # an allocation proxy.
  defp forex_value(%{} = account) do
    # OANDA's account map may use atom or string keys depending on
    # the API response shape; try both. NAV is preferred over
    # balance because it includes unrealized P&L.
    nav_val = forex_field(account, :nav) || forex_field(account, "NAV")
    bal_val = forex_field(account, :balance) || forex_field(account, "balance")

    cond do
      is_number(nav_val) -> nav_val * 1.0
      is_binary(nav_val) -> parse_float(nav_val)
      is_number(bal_val) -> bal_val * 1.0
      is_binary(bal_val) -> parse_float(bal_val)
      true -> 0.0
    end
  end

  defp forex_value(_), do: 0.0

  defp forex_field(%{} = m, key), do: Map.get(m, key)

  # Polymarket portfolio value — sum of notional `size × avg_price` across
  # paper/live positions. Position dollar value is approximate (Polymarket
  # prices fluctuate intra-trade), but this is the same notional method
  # the platform displays for open positions today. PnL is not yet
  # computed at the position level so we surface 0.0 — closed-position
  # PnL aggregation is a follow-up.
  defp polymarket_value(positions) when is_list(positions) do
    Enum.reduce(positions, 0.0, fn pos, acc ->
      acc + polymarket_position_notional(pos)
    end)
  end

  defp polymarket_value(_), do: 0.0

  defp polymarket_position_notional(%{size: size, avg_price: price}) do
    size_f = to_float_or_zero(size)
    price_f = to_float_or_zero(price)
    size_f * price_f
  end

  defp polymarket_position_notional(_), do: 0.0

  defp polymarket_loaded?(positions) when is_list(positions) and positions != [], do: true
  defp polymarket_loaded?(_), do: false

  defp polymarket_pnl(_positions), do: 0.0

  # P&L period selector (Phorari 9951 / CyberSec 9952). Only `:all_time`
  # has live data piped through the breakdown today — the other periods
  # are surfaced as "—" so the UI shape exists for when day_change /
  # week_change / month_change are wired in later.
  # Returns `{value, available?, label}`.
  defp portfolio_pnl_for_period(:all_time, combined), do: {combined, true, "All-Time"}
  defp portfolio_pnl_for_period(:today, _combined), do: {0.0, false, "Today"}
  defp portfolio_pnl_for_period(:week, _combined), do: {0.0, false, "This Week"}
  defp portfolio_pnl_for_period(:month, _combined), do: {0.0, false, "This Month"}
  defp portfolio_pnl_for_period(_, combined), do: {combined, true, "All-Time"}

  # Smart diversity caption for the donut hole baseline state. If no
  # broker holds >50% of the portfolio we read as diversified; otherwise
  # we call out the concentration.
  defp portfolio_diversity_caption(%{slices: slices, total_value: total}) when total > 0.0 do
    active = Enum.filter(slices, &(&1.value > 0))
    count = length(active)

    case Enum.max_by(active, & &1.percent, fn -> nil end) do
      nil ->
        "No broker balances loaded yet"

      top when top.percent > 50.0 ->
        "Concentrated in #{top.label} #{Float.round(top.percent, 0) |> trunc()}%"

      _ ->
        "Diversified across #{count} broker#{if count == 1, do: "", else: "s"}"
    end
  end

  defp portfolio_diversity_caption(_), do: "No broker balances loaded yet"

  defp to_float_or_zero(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float_or_zero(n) when is_number(n), do: n * 1.0
  defp to_float_or_zero(s) when is_binary(s), do: parse_float(s)
  defp to_float_or_zero(_), do: 0.0

  defp forex_loaded?(%{} = _account), do: true
  defp forex_loaded?(_), do: false

  # OANDA exposes mark-to-market unrealized P&L as `unrealizedPL`
  # on the account map (string key — OANDA convention). The same
  # field is rendered in the existing ForEx tab summary at
  # dashboard_live.ex line 4593, so this helper just normalizes
  # to float for the breakdown headline. ForEx settled / realized
  # P&L would require summing recent_trades — out of scope for
  # this PR; unrealized is the OANDA-side number Mico's spec
  # cares about.
  defp forex_unrealized_pnl(%{} = account) do
    raw = forex_field(account, :unrealizedPL) || forex_field(account, "unrealizedPL")

    cond do
      is_number(raw) -> raw * 1.0
      is_binary(raw) -> parse_float(raw)
      true -> 0.0
    end
  end

  defp forex_unrealized_pnl(_), do: 0.0

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # Maps Kalshi's market lifecycle status to a human label + Tailwind
  # badge classes. The dashboard renders this on every position row so
  # agents (and Mico) can tell at a glance which markets are still
  # tradable vs awaiting payout. See
  # https://docs.kalshi.com/getting_started/market_lifecycle for the
  # full state machine.
  defp kalshi_status_badge("active"),
    do: {"Active", "text-emerald-400 border-emerald-500/30 bg-emerald-500/10"}

  defp kalshi_status_badge("initialized"),
    do: {"Unopened", "text-gray-400 border-white/10 bg-white/[0.02]"}

  defp kalshi_status_badge("inactive"),
    do: {"Paused", "text-yellow-400 border-yellow-500/20 bg-yellow-500/5"}

  defp kalshi_status_badge("closed"),
    do: {"Closed", "text-gray-400 border-white/15 bg-white/[0.03]"}

  defp kalshi_status_badge("determined"),
    do: {"Determined", "text-blue-400 border-blue-500/20 bg-blue-500/10"}

  defp kalshi_status_badge("disputed"),
    do: {"Disputed", "text-orange-400 border-orange-500/30 bg-orange-500/10"}

  defp kalshi_status_badge("amended"),
    do: {"Amended", "text-purple-400 border-purple-500/20 bg-purple-500/10"}

  defp kalshi_status_badge("finalized"),
    do: {"Settled", "text-gray-500 border-white/10 bg-white/[0.02]"}

  defp kalshi_status_badge(_),
    do: {"—", "text-gray-600 border-white/10 bg-white/[0.02]"}

  # Kalshi orderbook responses are reciprocal between yes and no sides
  # (yes_ask = 100 - no_bid). For the dashboard's "Bid / Ask" column we
  # show whichever side the user actually holds: yes positions read
  # the yes-side quote, no positions read the no-side quote. Falls back
  # to the cached current_price when live levels aren't available
  # (e.g. enrichment failed or market is closed).
  defp kalshi_live_quote(%{
         side: "yes",
         live_yes_bid_cents: bid,
         live_yes_ask_cents: ask
       })
       when is_integer(bid) and is_integer(ask),
       do: "#{bid}¢ / #{ask}¢"

  defp kalshi_live_quote(%{
         side: "no",
         live_no_bid_cents: bid,
         live_no_ask_cents: ask
       })
       when is_integer(bid) and is_integer(ask),
       do: "#{bid}¢ / #{ask}¢"

  defp kalshi_live_quote(%{current_price: price}) when is_number(price) do
    "#{:erlang.float_to_binary(price * 100, decimals: 0)}¢"
  end

  defp kalshi_live_quote(_), do: "—"

  # Map the UI range label to Alpaca's portfolio_history {period, timeframe} params.
  # Alpaca period syntax: <n>(D|W|M|A), e.g. "3D", "1W", "1M", "1A" (1 year).
  # Timeframe grain: 15Min / 1H / 1D. We pick a grain that gives a useful
  # number of points without blowing past Alpaca's response limits.
  defp alpaca_period_to_api("1D"), do: {"1D", "15Min"}
  defp alpaca_period_to_api("3D"), do: {"3D", "1H"}
  defp alpaca_period_to_api("1W"), do: {"1W", "1H"}
  defp alpaca_period_to_api("1M"), do: {"1M", "1D"}
  defp alpaca_period_to_api("3M"), do: {"3M", "1D"}
  defp alpaca_period_to_api("6M"), do: {"6M", "1D"}
  defp alpaca_period_to_api("1Y"), do: {"1A", "1D"}
  defp alpaca_period_to_api("2Y"), do: {"2A", "1D"}
  defp alpaca_period_to_api("3Y"), do: {"3A", "1D"}
  defp alpaca_period_to_api("All"), do: {"10A", "1D"}
  defp alpaca_period_to_api(_), do: {"1M", "1D"}

  defp dashboard_tab_class("alpaca", active?),
    do: platform_dashboard_tab_class("kah-platform-alpaca", active?)

  defp dashboard_tab_class("kalshi", active?),
    do: platform_dashboard_tab_class("kah-platform-kalshi", active?)

  defp dashboard_tab_class("polymarket", active?),
    do: platform_dashboard_tab_class("kah-platform-polymarket", active?)

  defp dashboard_tab_class("forex", active?),
    do: platform_dashboard_tab_class("kah-platform-forex", active?)

  defp dashboard_tab_class(_tab_key, true), do: "border-b-2 border-[#22c55e] text-white"

  defp dashboard_tab_class(_tab_key, false),
    do: "border-b-2 border-transparent text-gray-500 hover:text-gray-300"

  defp platform_dashboard_tab_class(platform_class, true),
    do: "kah-platform-tab kah-platform-tab-active #{platform_class}"

  defp platform_dashboard_tab_class(platform_class, false),
    do: "kah-platform-tab kah-platform-tab-muted #{platform_class}"

  # Fallback for non-Codex setup snippets that are not tied to the selected agent.
  # Codex Option B is generated by CodexPrompts and never interpolates a token.
  @token_placeholder "kite_your_token_here"

  defp claude_code_prompt(agent) do
    name = if agent, do: agent.name, else: "Agent"

    # Inline the agent's real token so the paste is directly runnable.
    # The token is scoped to @selected_agent in mount (server-side only,
    # never pulled from URL params or shared state), and the rendered
    # block is masked + collapsible so the token isn't shoulder-surfable
    # before the user chooses to Reveal.
    token =
      case agent do
        %{api_token: t} when is_binary(t) and byte_size(t) > 0 -> t
        _ -> @token_placeholder
      end

    """
    You are #{name}, an autonomous trading agent connected to Kite Agent Hub (KAH).
    API base: https://kite-agent-hub.fly.dev/api/v1
    Auth header: Authorization: Bearer #{token}
    (This token is SECRET — never post it in chat or share it.)

    ## What KAH does for you
    KAH is the broker layer. You submit signals, KAH executes them on the
    correct platform (Alpaca for equities + crypto, Kalshi for prediction
    markets), polls for fills, settles the trade, and writes a Kite chain
    attestation for every settled trade. You never touch broker credentials.

    ## Endpoints
    - GET  /agents/me              — your profile + agent metadata
    - GET  /edge-scores            — live QRB scores for every open position + exit/hold suggestions
    - GET  /trades                 — your trade history (each row includes attestation_tx_hash + attestation_explorer_url once attested)
    - POST /trades                 — submit a trade signal (see payload below)
    - GET  /chat?after_id=<uuid>   — read recent chat messages
    - GET  /chat/wait?after_id=<uuid> — long-poll for chat, blocks up to 60s, 204 on timeout, 200 on new messages
    - POST /chat                   — post a message to the chat thread {text}

    ## Trade payload (POST /trades)
    {
      "market": "BTCUSD",        // Symbol. Crypto: BTCUSD/ETHUSD/SOLUSD (no slash). Equity: AAPL/SPY/etc. Auto-routed.
      "side": "long",            // "long" or "short" — your directional view
      "action": "buy",           // "buy" to open, "sell" to close. Always start with "buy".
      "contracts": 1,            // For crypto: whole units (1 = 1 BTC). For equities: shares.
      "fill_price": 71000.0,     // Your reference price; KAH submits a market order, this is informational.
      "reason": "edge=82, momentum strong" // Free-form rationale, surfaced on the dashboard.
    }
    KAH handles the rest: time_in_force, qty clamping to live position on sells, settlement polling, attestation.
    Response is 202 Accepted with the new trade id; poll GET /trades to see status flip from open → settled.

    ## Event loop (do NOT build a sleep loop — use the long-poll)
    1. GET /chat?limit=20 on startup. Remember the id of the newest message as last_seen_id.
    2. GET /chat/wait?after_id=<last_seen_id> — single curl, blocks up to 60s.
    3. On 200: process each message you have not seen. For each one not from yourself, reason and respond via POST /chat. Advance last_seen_id.
    4. On 204: reconnect immediately to step 2. Never sleep.
    5. Periodically (between chat events): GET /edge-scores. If a position recommends "exit" or your composite edge is below your threshold, send a closing trade (action="sell").

    ## Edge scoring (QRB)
    Every position scores 0-100: entry_quality (0-30) + momentum (0-25) + risk_reward (0-25) + liquidity (0-20).
    Buckets: strong_hold (75+), hold (60-74), watch (40-59), exit (<40).
    For NEW positions, the rule-based strategy admits anything >= 40 by default — anything higher is your call.

    ## Kite chain attestations (the proof)
    Every settled trade automatically gets a native KITE transfer on Kite chain, recorded on
    kitescan.ai (mainnet) or testnet.kitescan.ai (testnet). The tx hash is on the trade row as `attestation_tx_hash`, with a ready-built
    `attestation_explorer_url` link. You don't need to do anything to produce attestations — KAH does
    it after each settlement. You should mention them when reporting trade results in chat (it's the
    audit trail that makes you autonomous + verifiable).

    ## Style
    Keep messages short. You are talking to humans and other agents in a shared room. Avoid filler.
    When something fails, post the exact error string + the trade id so the team can grep logs.
    """
  end

  # Token mask: show first 8 chars + dots when collapsed.
  # e.g. "kite_abc12345••••••••"
  defp mask_token(nil), do: "(none)"

  defp mask_token(token) when is_binary(token) do
    case String.length(token) do
      n when n > 8 -> String.slice(token, 0, 8) <> "••••••••"
      _ -> String.duplicate("•", 12)
    end
  end

  defp explorer_tx_url(tx_hash, chain_id) do
    KiteAgentHub.Kite.Contracts.explorer_url(chain_id || 2368) <> "/tx/" <> (tx_hash || "")
  end

  defp explorer_address_url(address, chain_id) do
    KiteAgentHub.Kite.Contracts.explorer_url(chain_id || 2368) <>
      "/address/" <> (address || "")
  end

  defp rpc_chain(2366), do: :mainnet
  defp rpc_chain(_), do: :testnet
end
