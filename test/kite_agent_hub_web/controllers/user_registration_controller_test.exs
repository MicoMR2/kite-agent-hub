defmodule KiteAgentHubWeb.UserRegistrationControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.AccountsFixtures

  describe "GET /users/register" do
    test "renders registration page", %{conn: conn} do
      conn = get(conn, ~p"/users/register")
      response = html_response(conn, 200)
      assert response =~ "Create your account"
      assert response =~ ~p"/users/log-in"
      assert response =~ ~p"/users/register"
    end

    test "redirects if already logged in", %{conn: conn} do
      conn = conn |> log_in_user(user_fixture()) |> get(~p"/users/register")

      # Fresh registration creates user without agents, so
      # signed_in_path/1 routes to /onboard.
      assert redirected_to(conn) == ~p"/onboard"
    end
  end

  describe "POST /users/register" do
    @tag :capture_log
    test "creates account and redirects to log-in for email confirmation", %{conn: conn} do
      # Mico's call (per the controller comment): registration no longer
      # auto-logs the user in. The flow is register → confirm email via
      # magic-link → log in. So we assert the redirect + flash, not a
      # session token.
      email = unique_user_email()

      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{
            "email" => email,
            "password" => valid_user_password(),
            "accept_terms" => "true"
          }
        })

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
      assert conn.assigns.flash["info"] =~ "Check your email to confirm"
    end

    test "render errors for invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/users/register", %{
          "user" => %{"email" => "with spaces"}
        })

      response = html_response(conn, 200)
      assert response =~ "Create your account"
      assert response =~ "must have the @ sign and no spaces"
    end
  end
end
