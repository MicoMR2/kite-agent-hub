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

    if invite_only? do
      case Invites.peek(code) do
        {:ok, invite} ->
          if invite.email && String.downcase(invite.email) != String.downcase(user_params["email"] || "") do
            render_error(conn, "This invite code is for a different email address.")
          else
            do_register(conn, user_params, code)
          end

        {:error, _} ->
          render_error(conn, "Invalid, used, or expired invite code. Request a new one if you need access.")
      end
    else
      do_register(conn, user_params, nil)
    end
  end

  defp do_register(conn, user_params, code) do
    case Accounts.register_user_with_org(user_params) do
      {:ok, user} ->
        if code do
          # Best-effort consume after register; if the consume races and
          # loses we still let the registered user through (they got their
          # invite legitimately at peek time).
          _ = Invites.consume(code, user.email, user.id)
        end

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
          invite_status: %{state: :valid},
          invite_only?: Invites.enabled?()
        )

      {:error, _} ->
        render_error(conn, "Something went wrong. Please try again.")
    end
  end

  defp render_error(conn, msg) do
    conn
    |> put_flash(:error, msg)
    |> render(:new,
      changeset: Accounts.change_user_registration(%User{}),
      invite_code: "",
      invite_status: %{state: :invalid, reason: :rejected},
      invite_only?: Invites.enabled?()
    )
  end
end
