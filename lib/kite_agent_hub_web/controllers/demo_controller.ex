defmodule KiteAgentHubWeb.DemoController do
  @moduledoc """
  One-click demo login for hackathon judges.

  GET /demo looks up the user by DEMO_USER_EMAIL env var and creates
  a session for them, redirecting to /dashboard. The demo user must
  be pre-created via the normal registration flow.

  If DEMO_USER_EMAIL is not set or the user doesn't exist, redirects
  to the login page with an informational message.
  """

  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Accounts
  alias KiteAgentHubWeb.UserAuth

  def show(conn, _params) do
    case demo_user() do
      nil ->
        conn
        |> put_flash(:info, "Demo account not configured. Please sign in or register.")
        |> redirect(to: ~p"/users/log-in")

      user ->
        conn
        |> put_flash(:info, "Welcome! You are logged in as the demo account.")
        |> UserAuth.log_in_user(user)
    end
  end

  defp demo_user do
    case System.get_env("DEMO_USER_EMAIL") do
      nil -> nil
      "" -> nil
      email -> Accounts.get_user_by_email(email)
    end
  end
end
