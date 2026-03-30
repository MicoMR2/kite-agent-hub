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
        conn
        |> put_flash(:info, "Welcome to Kite Agent Hub!")
        |> KiteAgentHubWeb.UserAuth.log_in_user(user)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)

      {:error, _} ->
        conn
        |> put_flash(:error, "Something went wrong. Please try again.")
        |> render(:new, changeset: Accounts.change_user_registration(%User{}))
    end
  end
end
