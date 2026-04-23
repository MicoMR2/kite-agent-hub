defmodule KiteAgentHubWeb.OnboardingLive do
  @moduledoc """
  4-step welcome wizard shown to users who have not yet completed
  onboarding. Dismissal is persisted server-side on the `users`
  row, not in localStorage.
  """

  use KiteAgentHubWeb, :live_view

  require Logger
  alias KiteAgentHub.{Onboarding, Orgs, Wallets}

  @steps [:welcome, :fund, :connect, :ready]

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    # Users who registered before PR #198 shipped do not have a
    # wallet/vault/agent provisioned yet. Backfill idempotently so
    # legacy accounts can still walk through the wizard. Every DB
    # call is wrapped so a transient failure doesn't crash mount
    # and trigger a reconnect loop (per the KAH mount-loop rule).
    backfill_if_needed(user)

    wallet =
      try do
        Wallets.get_for_user(user)
      rescue
        e ->
          Logger.warning("OnboardingLive: Wallets.get_for_user failed: #{inspect(e)}")
          nil
      end

    socket =
      socket
      |> assign(:step, :welcome)
      |> assign(:steps, @steps)
      |> assign(:wallet, wallet)
      |> assign(:balance_display, balance_display(wallet))

    {:ok, socket}
  end

  # Precompute the balance string so the render path never hits a
  # function call that could raise on odd Ecto return types. If the
  # wallet or its field is missing/unexpected, fall back to $0.00
  # rather than crashing the LV and triggering a mount-loop.
  defp balance_display(nil), do: "$0.00"

  defp balance_display(%{balance_usd: %Decimal{} = d}) do
    "$" <> Decimal.to_string(d, :normal)
  end

  defp balance_display(%{balance_usd: n}) when is_number(n), do: "$#{n}"
  defp balance_display(%{balance_usd: s}) when is_binary(s), do: "$#{s}"
  defp balance_display(_), do: "$0.00"

  defp backfill_if_needed(user) do
    try do
      case Orgs.list_orgs_for_user(user.id) do
        [org | _] -> Onboarding.provision_for_user(user, org)
        _ -> :ok
      end
    rescue
      e ->
        # Mount must never crash on a DB blip — the wizard can still
        # render with a nil wallet, and the user can retry.
        Logger.warning("OnboardingLive backfill failed: #{inspect(e)}")
        :ok
    end
  end

  def handle_event("next", _params, socket) do
    next_step =
      case Enum.find_index(@steps, &(&1 == socket.assigns.step)) do
        nil -> :welcome
        i -> Enum.at(@steps, min(i + 1, length(@steps) - 1))
      end

    {:noreply, assign(socket, :step, next_step)}
  end

  def handle_event("back", _params, socket) do
    prev_step =
      case Enum.find_index(@steps, &(&1 == socket.assigns.step)) do
        nil -> :welcome
        i -> Enum.at(@steps, max(i - 1, 0))
      end

    {:noreply, assign(socket, :step, prev_step)}
  end

  # Catch-all so a stray phx-click event can never crash the LV and
  # trigger the mount-reconnect loop.
  def handle_event(event, params, socket) do
    Logger.warning("OnboardingLive: unhandled event #{inspect(event)} #{inspect(params)}")
    {:noreply, socket}
  end

  def handle_event("finish", _params, socket) do
    finish_and_go(socket)
  end

  def handle_event("skip", _params, socket) do
    finish_and_go(socket)
  end

  defp finish_and_go(socket) do
    user = socket.assigns.current_scope.user

    try do
      Onboarding.complete_onboarding(user)
    rescue
      e ->
        Logger.warning("Onboarding.complete_onboarding failed: #{inspect(e)}")
        :error
    end

    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-2xl mx-auto py-12 px-4">
        <div class="rounded-3xl border border-white/10 bg-[#0a0a0f] p-8 shadow-2xl">
          <div class="flex items-center justify-between mb-6">
            <h1 class="text-lg font-black uppercase tracking-widest text-white">
              Welcome to Kite Agent Hub
            </h1>
            <button
              phx-click="skip"
              class="text-[10px] font-bold text-gray-500 hover:text-gray-300 uppercase tracking-widest"
            >
              Skip
            </button>
          </div>

          <.progress_bar step={@step} steps={@steps} />

          <div class="mt-8 space-y-4">
            <%= case @step do %>
              <% :welcome -> %>
                <h2 class="text-2xl font-black text-white">What is Kite Agent Hub?</h2>
                <p class="text-sm text-gray-400 leading-relaxed">
                  Kite Agent Hub lets you run autonomous AI trading agents
                  across Alpaca stocks, Kalshi prediction markets, OANDA
                  forex, and Polymarket. You fund a wallet, connect a
                  brokerage, and the agent trades for you.
                </p>
              <% :fund -> %>
                <h2 class="text-2xl font-black text-white">Fund your wallet</h2>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                  <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                    Current balance
                  </p>
                  <p class="text-3xl font-black text-emerald-400 font-mono mt-1">
                    {@balance_display}
                  </p>
                  <p class="text-xs text-gray-500 mt-3">
                    Funding (Stripe + crypto) is coming soon. For now, you
                    can start by connecting a brokerage account and trading
                    on that platform's balance directly.
                  </p>
                </div>
              <% :connect -> %>
                <h2 class="text-2xl font-black text-white">Connect a platform</h2>
                <p class="text-sm text-gray-400 leading-relaxed">
                  Your default agent is ready to trade as soon as you add
                  credentials for at least one platform. You can manage
                  these in
                  <.link navigate={~p"/api-keys"} class="text-emerald-400 hover:underline">
                    API Keys
                  </.link>
                  after onboarding.
                </p>
                <ul class="text-xs text-gray-400 space-y-2 mt-4">
                  <li>
                    • <strong class="text-white">Alpaca</strong> — stocks + options (paper or live)
                  </li>
                  <li>• <strong class="text-white">OANDA</strong> — FX pairs (practice or live)</li>
                  <li>• <strong class="text-white">Kalshi</strong> — prediction markets</li>
                  <li>
                    • <strong class="text-white">Polymarket</strong> — crypto prediction markets
                  </li>
                </ul>
              <% :ready -> %>
                <h2 class="text-2xl font-black text-white">Your agent is ready</h2>
                <p class="text-sm text-gray-400 leading-relaxed">
                  We created a default agent named <strong class="text-white">Trading Agent</strong>
                  for you. You can rename it, switch its type to research
                  or conversational, or wire up its LLM provider from the
                  dashboard.
                </p>
            <% end %>
          </div>

          <div class="mt-10 flex items-center justify-between">
            <%= if @step == :welcome do %>
              <span></span>
            <% else %>
              <button
                phx-click="back"
                class="text-xs font-bold text-gray-500 hover:text-white uppercase tracking-widest"
              >
                ← Back
              </button>
            <% end %>

            <%= if @step == :ready do %>
              <button
                phx-click="finish"
                class="px-5 py-2.5 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-black text-xs font-black uppercase tracking-widest transition-colors"
              >
                Go to Dashboard →
              </button>
            <% else %>
              <button
                phx-click="next"
                class="px-5 py-2.5 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-black text-xs font-black uppercase tracking-widest transition-colors"
              >
                Next →
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :step, :atom, required: true
  attr :steps, :list, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <%= for s <- @steps do %>
        <div class={[
          "h-1 flex-1 rounded-full transition-colors",
          if(step_index(@step, @steps) >= step_index(s, @steps),
            do: "bg-emerald-500",
            else: "bg-white/10"
          )
        ]}>
        </div>
      <% end %>
    </div>
    """
  end

  defp step_index(step, steps), do: Enum.find_index(steps, &(&1 == step)) || 0

  def steps, do: @steps
end
