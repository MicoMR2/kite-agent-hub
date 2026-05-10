defmodule KiteAgentHubWeb.UserRegistrationController do
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Accounts
  alias KiteAgentHub.Accounts.{Invites, User}

  def new(conn, params) do
    code = params["code"] || ""
    changeset = Accounts.change_user_registration(%User{})

    code_status =
      if Invites.enabled?() do
        case Invites.peek(code) do
          {:ok, invite} -> %{state: :valid, email: invite.email}
          {:error, :invalid} when code == "" -> %{state: :missing}
          {:error, reason} -> %{state: :invalid, reason: reason}
        end
      else
        %{state: :disabled}
      end

    render(conn, :new,
      changeset: changeset,
      invite_code: code,
      invite_status: code_status,
      invite_only?: Invites.enabled?()
    )
  end

  def create(conn, %{"user" => user_params} = params) do
    code = params["invite_code"] || user_params["invite_code"] || ""
    invite_only? = Invites.enabled?()
    code = if invite_only?, do: code, else: nil

    case Accounts.register_user_with_org(user_params, invite_code: code) do
      {:ok, user} ->
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
        render(conn, :new,
          changeset: changeset,
          invite_code: code || "",
          invite_status: %{state: if(invite_only?, do: :valid, else: :disabled)},
          invite_only?: invite_only?
        )

      {:error, {:invite, reason}} ->
        msg =
          case reason do
            :code_required -> "An invite code is required to sign up. Request access first."
            :invalid_or_used -> "Invalid, used, or expired invite code."
            _ -> "Invalid invite code."
          end

        conn
        |> put_flash(:error, msg)
        |> redirect(to: ~p"/users/register")

      {:error, _} ->
        conn
        |> put_flash(:error, "Something went wrong. Please try again.")
        |> render(:new,
          changeset: Accounts.change_user_registration(%User{}),
          invite_code: code || "",
          invite_status: %{state: if(invite_only?, do: :valid, else: :disabled)},
          invite_only?: invite_only?
        )
    end
  end
end
