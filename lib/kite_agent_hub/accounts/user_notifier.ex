defmodule KiteAgentHub.Accounts.UserNotifier do
  import Swoosh.Email

  alias KiteAgentHub.Mailer
  alias KiteAgentHub.Accounts.User

  # Default from-address. If MAILER_FROM_EMAIL is unset (or set to a custom
  # domain that hasn't been verified in Resend yet) we fall back to Resend's
  # always-deliverable sandbox sender so signup emails don't silently fail.
  @sandbox_from "Kite Agent Hub <onboarding@resend.dev>"

  defp mailer_from do
    Application.get_env(:kite_agent_hub, :mailer_from_email, @sandbox_from)
  end

  defp deliver(recipient, subject, html, text) do
    email =
      new()
      |> to(recipient)
      |> from(mailer_from())
      |> subject(subject)
      |> text_body(text)
      |> html_body(html)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  ## ────── HTML shell ──────────────────────────────────────────────────────

  # Single shared template — dark canvas (#0a0a0f), green accent border, KAH
  # wordmark + chain pill, big content panel. `headline` is the visible H1,
  # `body` is the inner HTML chunk supplied by each notifier function.
  defp shell(headline, body_html) do
    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>#{headline}</title></head>
    <body style="margin:0;padding:0;background:#0a0a0f;font-family:'Helvetica Neue',Arial,sans-serif;color:#e5e7eb;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#0a0a0f;padding:32px 0;">
        <tr><td align="center">
          <table role="presentation" width="560" cellspacing="0" cellpadding="0" border="0" style="background:#0d0d12;border:1px solid rgba(255,255,255,0.10);border-radius:16px;overflow:hidden;max-width:560px;">
            <tr><td style="padding:28px 32px 0 32px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="left">
                    <span style="display:inline-block;font-weight:800;letter-spacing:-0.01em;color:#ffffff;font-size:18px;">Kite Agent Hub</span>
                  </td>
                  <td align="right">
                    <span style="display:inline-block;padding:4px 10px;border-radius:9999px;border:1px solid rgba(34,197,94,0.30);background:rgba(34,197,94,0.10);color:#4ade80;font-size:11px;font-weight:600;letter-spacing:0.06em;text-transform:uppercase;">Testnet · 2368</span>
                  </td>
                </tr>
              </table>
            </td></tr>
            <tr><td style="padding:24px 32px 8px 32px;">
              <h1 style="margin:0;color:#ffffff;font-size:24px;line-height:1.2;font-weight:800;letter-spacing:-0.02em;">#{headline}</h1>
            </td></tr>
            <tr><td style="padding:8px 32px 28px 32px;color:#cbd5e1;font-size:15px;line-height:1.6;">
              #{body_html}
            </td></tr>
            <tr><td style="padding:18px 32px 28px 32px;border-top:1px solid rgba(255,255,255,0.06);color:#6b7280;font-size:11px;letter-spacing:0.08em;text-transform:uppercase;font-family:'JetBrains Mono','Courier New',monospace;">
              Kite Agent Hub · Non-custodial AI trading · kiteagenthub.com
            </td></tr>
          </table>
        </td></tr>
      </table>
    </body></html>
    """
  end

  defp button(label, href) do
    """
    <p style="margin:24px 0 8px 0;">
      <a href="#{href}" style="display:inline-block;background:#16a34a;color:#ffffff;text-decoration:none;font-weight:700;font-size:14px;padding:13px 22px;border-radius:12px;box-shadow:0 0 30px rgba(34,197,94,0.25);">#{label}</a>
    </p>
    """
  end

  defp escape(nil), do: ""
  defp escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  ## ────── Settings flows (existing) ────────────────────────────────────────

  def deliver_update_email_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.
    """

    html =
      shell("Update your email", """
      <p>Hi #{escape(user.email)},</p>
      <p>You requested an email-address change on your Kite Agent Hub account. Confirm the new address with the button below — the link is single-use and expires shortly.</p>
      #{button("Confirm new email →", url)}
      <p style="color:#94a3b8;font-size:13px;">If you didn't request this, ignore this email — your existing address stays in place.</p>
      """)

    deliver(user.email, "Update email instructions", html, text)
  end

  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.
    """

    html =
      shell("Sign in to Kite Agent Hub", """
      <p>Hi #{escape(user.email)},</p>
      <p>Use the button below to sign in. The link is single-use and expires shortly.</p>
      #{button("Sign in →", url)}
      <p style="color:#94a3b8;font-size:13px;">If this wasn't you, ignore this email — your account stays where it is.</p>
      """)

    deliver(user.email, "Sign in to Kite Agent Hub", html, text)
  end

  defp deliver_confirmation_instructions(user, url) do
    text = """
    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.
    """

    html =
      shell("Confirm your account", """
      <p>Hi #{escape(user.email)},</p>
      <p>Welcome aboard. Confirm your account to finish onboarding — the link is single-use and expires shortly.</p>
      #{button("Confirm account →", url)}
      <p style="color:#94a3b8;font-size:13px;">Didn't sign up? Ignore this email.</p>
      """)

    deliver(user.email, "Confirm your Kite Agent Hub account", html, text)
  end

  ## ────── Invite-flow notifiers ───────────────────────────────────────────

  @doc """
  Notify the admin that a new access request has been submitted.
  """
  def deliver_access_request_notification(req) do
    to = Application.get_env(:kite_agent_hub, :admin_notification_email, "support@kiteagenthub.com")
    base_url = Application.get_env(:kite_agent_hub, :app_base_url, "https://kiteagenthub.com")
    review_url = base_url <> "/admin/access-requests"
    notes_block_text = if req.notes && req.notes != "", do: "Notes: #{req.notes}\n\n", else: ""

    notes_block_html =
      if req.notes && req.notes != "" do
        ~s|<p style="margin:18px 0 0 0;padding:14px 16px;border-left:2px solid rgba(34,197,94,0.50);background:rgba(34,197,94,0.05);color:#cbd5e1;font-size:14px;line-height:1.6;white-space:pre-wrap;">#{escape(req.notes)}</p>|
      else
        ""
      end

    text = """
    A new user has requested access to Kite Agent Hub.

    Name:  #{req.name}
    Email: #{req.email}

    #{notes_block_text}Review and generate an invite code:
    #{review_url}
    """

    html =
      shell("New access request", """
      <p>Someone wants in.</p>
      <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:14px 0 10px 0;">
        <tr>
          <td style="padding:6px 0;color:#94a3b8;font-size:12px;letter-spacing:0.08em;text-transform:uppercase;">Name</td>
          <td style="padding:6px 0 6px 18px;color:#ffffff;font-weight:600;font-size:15px;">#{escape(req.name)}</td>
        </tr>
        <tr>
          <td style="padding:6px 0;color:#94a3b8;font-size:12px;letter-spacing:0.08em;text-transform:uppercase;">Email</td>
          <td style="padding:6px 0 6px 18px;color:#ffffff;font-family:'JetBrains Mono',monospace;font-size:14px;">#{escape(req.email)}</td>
        </tr>
      </table>
      #{notes_block_html}
      #{button("Review in admin →", review_url)}
      """)

    deliver(to, "New access request — #{req.email}", html, text)
  end

  @doc """
  Confirmation email sent to the requester right after they submit
  /request-access. Sets expectations: we got it, we'll review, you'll
  hear back.
  """
  def deliver_request_receipt(req) do
    text = """
    Hi #{req.name},

    We received your request for access to Kite Agent Hub. We'll review it and get back to you by email — usually within a day.

    Once approved, you'll receive a one-time invite code that's locked to this email address (#{req.email}). The code is good for 14 days.

    No action needed right now.
    """

    html =
      shell("We got your request", """
      <p>Hi #{escape(req.name)},</p>
      <p>Thanks for your interest in Kite Agent Hub. We've received your request and will review it manually — usually within a day.</p>
      <p>Once approved, you'll get a follow-up email with a one-time invite code locked to <span style="color:#ffffff;font-family:'JetBrains Mono',monospace;">#{escape(req.email)}</span>. The code is good for 14 days.</p>
      <p style="color:#94a3b8;font-size:13px;">Nothing to do right now — sit tight.</p>
      """)

    deliver(req.email, "Your Kite Agent Hub access request", html, text)
  end

  @doc """
  Deliver an invite code to the requester after admin approval.
  """
  def deliver_invite_code(email, plaintext_code, base_url) do
    register_url = "#{base_url}/users/register?code=#{plaintext_code}"

    text = """
    Your access to Kite Agent Hub has been approved.

    Use this one-time code to finish signing up — it expires in 14 days and is locked to #{email}.

    Code: #{plaintext_code}

    Or sign up directly:
    #{register_url}

    If this wasn't you, ignore this email.
    """

    html =
      shell("You're in.", """
      <p>Your access has been approved. Use the code below to finish signing up — it's good for 14 days and locked to this email address.</p>
      <p style="margin:22px 0;padding:18px;background:rgba(34,197,94,0.08);border:1px solid rgba(34,197,94,0.35);border-radius:12px;text-align:center;font-family:'JetBrains Mono','Courier New',monospace;font-size:20px;letter-spacing:0.08em;color:#4ade80;">#{escape(plaintext_code)}</p>
      #{button("Sign up with this code →", register_url)}
      <p style="color:#94a3b8;font-size:13px;">If this wasn't you, ignore this email — the code is bound to <span style="color:#cbd5e1;font-family:'JetBrains Mono',monospace;">#{escape(email)}</span>.</p>
      """)

    deliver(email, "You're invited to Kite Agent Hub", html, text)
  end
end
