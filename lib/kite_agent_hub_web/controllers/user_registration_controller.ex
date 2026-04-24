defmodule KiteAgentHubWeb.UserRegistrationController do
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Accounts
  alias KiteAgentHub.Accounts.User

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user_with_org(user_params) do
      {:ok, user} ->
        # Mico (msg 7676) wants the email-confirmation gate preserved:
        # "a small bit of friction where it matters adds a feeling of
        # security." Deliver the verification email and redirect to
        # /users/log-in. After the user clicks the link and logs in,
        # signed_in_path/1 sends them to /onboard to continue onboarding
        # if they still need venues/agent, or /dashboard if already set.
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        conn
        |> put_session(:user_return_to, ~p"/onboard")
        |> put_flash(
          :info,
          "Account created. Check your email to confirm, then sign in to finish onboarding."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)

      {:error, _} ->
        conn
        |> put_flash(:error, "Something went wrong. Please try again.")
        |> render(:new, changeset: Accounts.change_user_registration(%User{}))
    end
  end
end
