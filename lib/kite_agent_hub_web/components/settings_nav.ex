defmodule KiteAgentHubWeb.SettingsNav do
  @moduledoc """
  Shared tab navigation for the Settings area (Account / API Keys / Workspace).
  Renders the top breadcrumb and tab bar used across
  `UserSettingsController`, `ApiKeysLive`, and `WorkspaceLive`.

  ## Usage

      <SettingsNav.render active={:account} />
      <SettingsNav.render active={:api_keys} />
      <SettingsNav.render active={:workspace} />
  """

  use Phoenix.Component

  import KiteAgentHubWeb.CoreComponents, only: [icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: KiteAgentHubWeb.Endpoint,
    router: KiteAgentHubWeb.Router,
    statics: KiteAgentHubWeb.static_paths()

  @tabs [
    {:account, "Account", "/users/settings"},
    {:agents, "Agents", "/users/settings/agents"},
    {:api_keys, "API Keys", "/users/settings/api-keys"},
    {:workspace, "Workspace", "/users/settings/workspace"}
  ]

  attr :active, :atom, required: true, values: [:account, :agents, :api_keys, :workspace]

  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div>
      <%!-- Breadcrumb --%>
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
            :for={{key, label, path} <- @tabs}
            navigate={path}
            class={[
              "px-4 py-3 text-xs font-black uppercase tracking-widest border-b-2 transition-all",
              @active == key && "text-white border-white",
              @active != key && "text-gray-500 hover:text-white border-transparent hover:border-white/20"
            ]}
          >
            {label}
          </.link>
        </nav>
      </div>
    </div>
    """
  end
end
