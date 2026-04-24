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
        # Verification email still goes out in the background —
        # onboarding is not gated on it per msg 7671 (CyberSec CLEAR).
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        conn
        |> put_flash(
          :info,
          "Account created. Verification email on the way — you can finish onboarding now."
        )
        |> KiteAgentHubWeb.UserAuth.log_in_new_user(user)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)

      {:error, _} ->
        conn
        |> put_flash(:error, "Something went wrong. Please try again.")
        |> render(:new, changeset: Accounts.change_user_registration(%User{}))
    end
  end
end
