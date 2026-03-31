defmodule KiteAgentHubWeb.WorkOSAuthController do
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.Accounts
  alias KiteAgentHub.WorkOS
  alias KiteAgentHubWeb.UserAuth

  @doc """
  Redirects user to WorkOS AuthKit for authentication.
  Stores a CSRF state token in the session to validate the callback.
  """
  def authorize(conn, _params) do
    unless WorkOS.configured?() do
      conn
      |> put_flash(:error, "SSO is not configured. Please use email and password to log in.")
      |> redirect(to: ~p"/users/log-in")
      |> halt()
    end

    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    auth_url = WorkOS.authorization_url(state)

    conn
    |> put_session(:workos_oauth_state, state)
    |> redirect(external: auth_url)
  end

  @doc """
  Handles the WorkOS OAuth callback.
  Exchanges the authorization code for user data, then finds or creates the user.
  """
  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :workos_oauth_state)

    if expected_state && state == expected_state do
      conn = delete_session(conn, :workos_oauth_state)

      case WorkOS.authenticate_with_code(code) do
        {:ok, workos_attrs} ->
          case Accounts.find_or_create_workos_user(workos_attrs) do
            {:ok, user} ->
              UserAuth.log_in_user(conn, user)

            {:error, _changeset} ->
              conn
              |> put_flash(:error, "Could not sign you in. Please try again.")
              |> redirect(to: ~p"/users/log-in")
          end

        {:error, reason} ->
          Logger.error("WorkOS auth failed: #{reason}")

          conn
          |> put_flash(:error, "Authentication failed. Please try again.")
          |> redirect(to: ~p"/users/log-in")
      end
    else
      conn
      |> put_flash(:error, "Invalid or expired authentication request.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Authentication was cancelled or failed.")
    |> redirect(to: ~p"/users/log-in")
  end
end
