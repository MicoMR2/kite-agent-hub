defmodule KiteAgentHubWeb.Router do
  use KiteAgentHubWeb, :router

  import KiteAgentHubWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KiteAgentHubWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", KiteAgentHubWeb do
    pipe_through :browser

    live_session :public, on_mount: [{KiteAgentHubWeb.UserAuth, :mount_current_scope}] do
      live "/", HomeLive
    end
  end

  # External agent API — stateless JSON, auth via Bearer wallet_address
  scope "/api/v1", KiteAgentHubWeb.API do
    pipe_through :api

    post "/trades", TradesController, :create
    get "/trades", TradesController, :index
    get "/trades/:id", TradesController, :show
    get "/agents/me", TradesController, :agent_me
    post "/chat", ChatController, :create
    get "/chat", ChatController, :index
    get "/chat/wait", ChatController, :wait
    get "/edge-scores", EdgeScoresController, :index
    get "/score", ScoreController, :show
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:kite_agent_hub, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: KiteAgentHubWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", KiteAgentHubWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", KiteAgentHubWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", KiteAgentHubWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [{KiteAgentHubWeb.UserAuth, :require_authenticated}] do
      live "/dashboard", DashboardLive
      live "/agents/new", AgentOnboardLive
      live "/trades", TradesLive
      live "/api-keys", ApiKeysLive
      live "/users/settings/api-keys", ApiKeysLive, :settings
      live "/users/settings/workspace", WorkspaceLive
    end
  end

  scope "/", KiteAgentHubWeb do
    pipe_through [:browser]

    get "/demo", DemoController, :show

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete

    # Aliases — Phoenix.gen.auth historically used `log_in`/`log_out`
    # with underscores. Stale browser bookmarks and any external link
    # using the old form land on a 404 today. Redirect them to the
    # canonical hyphen form so old links keep working.
    get "/users/log_in", LoginAliasController, :show
    delete "/users/log_out", LoginAliasController, :delete
  end

  # WorkOS OAuth — open to all (unauthenticated users initiate here)
  scope "/auth", KiteAgentHubWeb do
    pipe_through :browser

    get "/workos", WorkOSAuthController, :authorize
    get "/workos/callback", WorkOSAuthController, :callback
  end
end
