defmodule KiteAgentHub.Accounts.UserNotifier do
  import Swoosh.Email

  alias KiteAgentHub.Mailer
  alias KiteAgentHub.Accounts.User

  # Delivers the email using the application mailer.
  # From-address is read from Application env at runtime (set via MAILER_FROM_EMAIL
  # in runtime.exs) so it can be changed without a code redeploy. Falls back to
  # Resend's free sandbox address so emails work immediately even before a custom
  # domain is verified in Resend.
  defp mailer_from do
    Application.get_env(:kite_agent_hub, :mailer_from_email, "Kite Agent Hub <onboarding@resend.dev>")
  end

  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(mailer_from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  @doc """
  Notify the admin that a new access request has been submitted.
  """
  def deliver_access_request_notification(req) do
    to = Application.get_env(:kite_agent_hub, :admin_notification_email, "support@kiteagenthub.com")
    base_url = Application.get_env(:kite_agent_hub, :app_base_url, "https://kiteagenthub.com")
    review_url = base_url <> "/admin/access-requests"
    notes = if req.notes && req.notes != "", do: "Notes: #{req.notes}\n\n", else: ""

    deliver(to, "New access request — #{req.email}", """

    ==============================

    A new user has requested access to Kite Agent Hub.

    Name:  #{req.name}
    Email: #{req.email}

    #{notes}Review and generate an invite code:
    #{review_url}

    ==============================
    """)
  end

  @doc """
  Deliver an invite code to the requester after admin approval.
  """
  def deliver_invite_code(email, plaintext_code, base_url) do
    register_url = "#{base_url}/users/register?code=#{plaintext_code}"

    deliver(email, "You're invited to Kite Agent Hub", """

    ==============================

    Your access to Kite Agent Hub has been approved.

    Use this one-time code to finish signing up — it expires in 14 days.

    Code: #{plaintext_code}

    Or click directly:
    #{register_url}

    If this wasn't you, ignore this email — the code is bound to this address.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
