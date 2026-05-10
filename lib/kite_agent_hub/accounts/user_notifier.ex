defmodule KiteAgentHub.Accounts.UserNotifier do
  import Swoosh.Email

  alias KiteAgentHub.Mailer
  alias KiteAgentHub.Accounts.User

  # Default from-address. If MAILER_FROM_EMAIL is unset we fall back to
  # Resend's always-deliverable sandbox sender so signup emails don't
  # silently fail on an unverified custom domain.
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

  # Inline SVG kite mark. 4 brand circles — blue / purple / white / green.
  # Inline so it renders without a remote-image fetch (Gmail/Outlook block
  # those by default).
  @logo_svg ~s|<svg width="36" height="36" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg" style="display:block;"><circle cx="24" cy="30" r="26" fill="#60a5fa"/><circle cx="156" cy="30" r="26" fill="#c084fc"/><circle cx="90" cy="168" r="26" fill="#ffffff"/><circle cx="90" cy="90" r="34" fill="#22c55e"/></svg>|

  # `eyebrow` — short uppercase mono label above the headline (e.g. "INVITED")
  # `headline` — already-built HTML string for the H1 (allows <em> serif accent)
  # `body` — inner content HTML
  defp shell(eyebrow, headline, body) do
    """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>Kite Agent Hub</title>
    <meta name="viewport" content="width=device-width,initial-scale=1">
    </head>
    <body style="margin:0;padding:0;background:#0a0a0f;font-family:'Helvetica Neue','Inter',Arial,sans-serif;color:#e5e7eb;-webkit-font-smoothing:antialiased;">
      <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:linear-gradient(180deg,#0a0a0f 0%,#0d100e 60%,#0a0a0f 100%);padding:40px 16px;">
        <tr><td align="center">
          <table role="presentation" width="600" cellspacing="0" cellpadding="0" border="0" style="background:#0d0d12;border:1px solid rgba(255,255,255,0.08);border-radius:20px;overflow:hidden;max-width:600px;box-shadow:0 30px 80px rgba(0,0,0,0.50);">
            <tr><td style="padding:30px 40px 0 40px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td align="left" valign="middle">
                    <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
                      <td valign="middle" style="padding-right:10px;">#{@logo_svg}</td>
                      <td valign="middle" style="font-weight:800;letter-spacing:-0.015em;color:#ffffff;font-size:18px;line-height:1;">Kite Agent Hub</td>
                    </tr></table>
                  </td>
                  <td align="right">
                    <span style="display:inline-block;padding:5px 11px;border-radius:9999px;border:1px solid rgba(34,197,94,0.30);background:rgba(34,197,94,0.10);color:#4ade80;font-size:11px;font-weight:600;letter-spacing:0.10em;text-transform:uppercase;font-family:'JetBrains Mono','Courier New',monospace;">Testnet · 2368</span>
                  </td>
                </tr>
              </table>
            </td></tr>
            <tr><td style="padding:36px 40px 6px 40px;">
              <p style="margin:0 0 14px 0;color:#4ade80;font-family:'JetBrains Mono','Courier New',monospace;font-size:11px;font-weight:600;letter-spacing:0.22em;text-transform:uppercase;">#{escape(eyebrow)}</p>
              <h1 style="margin:0;color:#ffffff;font-size:34px;line-height:1.05;font-weight:800;letter-spacing:-0.025em;">#{headline}</h1>
            </td></tr>
            <tr><td style="padding:18px 40px 8px 40px;">
              <div style="height:1px;background:linear-gradient(90deg,transparent,rgba(34,197,94,0.30),transparent);font-size:0;line-height:0;">&nbsp;</div>
            </td></tr>
            <tr><td style="padding:8px 40px 36px 40px;color:#cbd5e1;font-size:16px;line-height:1.65;">
              #{body}
            </td></tr>
            <tr><td style="padding:20px 40px 26px 40px;border-top:1px solid rgba(255,255,255,0.06);">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
                <td align="left" style="color:#6b7280;font-size:11px;letter-spacing:0.10em;text-transform:uppercase;font-family:'JetBrains Mono','Courier New',monospace;">
                  Apache 2.0 · Non-custodial
                </td>
                <td align="right" style="color:#6b7280;font-size:11px;letter-spacing:0.10em;text-transform:uppercase;font-family:'JetBrains Mono','Courier New',monospace;">
                  kiteagenthub.com
                </td>
              </tr></table>
            </td></tr>
          </table>
        </td></tr>
      </table>
    </body></html>
    """
  end

  defp button(label, href) do
    """
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:28px 0 8px 0;">
      <tr><td style="border-radius:14px;background:#16a34a;box-shadow:0 0 40px rgba(34,197,94,0.30);">
        <a href="#{href}" style="display:inline-block;color:#ffffff;text-decoration:none;font-weight:700;font-size:15px;letter-spacing:-0.01em;padding:15px 26px;border-radius:14px;">#{label}</a>
      </td></tr>
    </table>
    """
  end

  # Italic-serif accent — same move as the landing italic-serif treatment
  # but keyed on font-family system serifs so it renders consistently in
  # email clients that won't load a custom font.
  defp accent(word) do
    ~s|<em style="font-family:Georgia,'Times New Roman',serif;font-style:italic;font-weight:600;color:#ffffff;letter-spacing:-0.01em;">#{escape(word)}</em>|
  end

  defp steps(items) do
    rows =
      items
      |> Enum.with_index(1)
      |> Enum.map(fn {text, n} ->
        ~s|<tr>
          <td valign="top" width="38" style="padding:10px 14px 10px 0;">
            <span style="display:inline-block;width:28px;height:28px;border-radius:9999px;border:1px solid rgba(34,197,94,0.40);background:rgba(34,197,94,0.10);color:#4ade80;font-family:'JetBrains Mono','Courier New',monospace;font-size:12px;font-weight:600;line-height:28px;text-align:center;">#{n}</span>
          </td>
          <td valign="middle" style="padding:10px 0;color:#cbd5e1;font-size:14px;line-height:1.55;">#{text}</td>
        </tr>|
      end)
      |> Enum.join("")

    ~s|<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:18px 0 6px 0;border-top:1px solid rgba(255,255,255,0.06);">#{rows}</table>|
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
      shell(
        "Email change",
        "Confirm your #{accent("new")} address.",
        """
        <p>You requested an email-address change on your Kite Agent Hub account. Confirm the new address below — the link is single-use and expires shortly.</p>
        #{button("Confirm new email →", url)}
        <p style="color:#94a3b8;font-size:13px;margin-top:18px;">Didn't request this? Ignore — your existing address stays in place.</p>
        """
      )

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
      shell(
        "Sign in",
        "Welcome #{accent("back")}.",
        """
        <p>Use the button below to sign in. The link is single-use and expires shortly.</p>
        #{button("Sign in →", url)}
        <p style="color:#94a3b8;font-size:13px;margin-top:18px;">Didn't request this? Ignore — your account stays where it is.</p>
        """
      )

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
      shell(
        "Welcome",
        "One #{accent("click")} to finish.",
        """
        <p>Welcome aboard. Confirm your account to finish onboarding — the link is single-use and expires shortly.</p>
        #{button("Confirm account →", url)}
        <p style="color:#94a3b8;font-size:13px;margin-top:18px;">Didn't sign up? Ignore this email.</p>
        """
      )

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
        ~s|<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:18px 0 0 0;"><tr><td style="padding:14px 16px;border-left:3px solid rgba(34,197,94,0.55);background:rgba(34,197,94,0.05);color:#cbd5e1;font-size:14px;line-height:1.6;white-space:pre-wrap;">#{escape(req.notes)}</td></tr></table>|
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
      shell(
        "New request",
        "Someone wants #{accent("in")}.",
        """
        <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:14px 0 4px 0;">
          <tr>
            <td style="padding:6px 0;color:#94a3b8;font-size:11px;letter-spacing:0.10em;text-transform:uppercase;font-family:'JetBrains Mono','Courier New',monospace;">Name</td>
            <td style="padding:6px 0 6px 22px;color:#ffffff;font-weight:600;font-size:16px;">#{escape(req.name)}</td>
          </tr>
          <tr>
            <td style="padding:6px 0;color:#94a3b8;font-size:11px;letter-spacing:0.10em;text-transform:uppercase;font-family:'JetBrains Mono','Courier New',monospace;">Email</td>
            <td style="padding:6px 0 6px 22px;color:#ffffff;font-family:'JetBrains Mono','Courier New',monospace;font-size:14px;">#{escape(req.email)}</td>
          </tr>
        </table>
        #{notes_block_html}
        #{button("Review in admin →", review_url)}
        """
      )

    deliver(to, "New access request — #{req.email}", html, text)
  end

  @doc """
  Confirmation email sent to the requester right after they submit
  /request-access.
  """
  def deliver_request_receipt(req) do
    text = """
    Hi #{req.name},

    We received your request for access to Kite Agent Hub. We'll review it and get back to you by email — usually within a day.

    Once approved, you'll receive a one-time invite code that's locked to this email address (#{req.email}). The code is good for 14 days.

    No action needed right now.
    """

    html =
      shell(
        "Received",
        "We've got #{accent("you")}. Hang tight.",
        """
        <p>Hi #{escape(req.name)} — thanks for your interest in Kite Agent Hub. We received your access request and will review it personally, usually within a day.</p>
        #{steps([
          "We review your request and confirm fit.",
          ~s|You receive a follow-up email with a one-time invite code locked to <span style="color:#ffffff;font-family:'JetBrains Mono',monospace;">#{escape(req.email)}</span>.|,
          "You finish signing up and deploy your first agent."
        ])}
        <p style="color:#94a3b8;font-size:13px;margin-top:22px;">Nothing to do right now — sit tight.</p>
        """
      )

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
      shell(
        "Invited",
        "You're #{accent("in")}.",
        """
        <p style="font-size:17px;color:#e5e7eb;">Welcome to Kite Agent Hub. Your access is approved — use the code below to finish signing up.</p>
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:24px 0 22px 0;">
          <tr><td style="padding:22px;background:rgba(34,197,94,0.06);border:1px solid rgba(34,197,94,0.40);border-radius:14px;text-align:center;font-family:'JetBrains Mono','Courier New',monospace;font-size:22px;letter-spacing:0.16em;color:#4ade80;font-weight:600;">#{escape(plaintext_code)}</td></tr>
        </table>
        #{button("Sign up with this code →", register_url)}
        #{steps([
          "Click the button above (or paste the code on the signup page).",
          ~s|We pre-fill your email as <span style="color:#ffffff;font-family:'JetBrains Mono',monospace;">#{escape(email)}</span> — set a password.|,
          "Confirm via the email we send you, then deploy your first agent."
        ])}
        <p style="color:#94a3b8;font-size:13px;margin-top:22px;">14-day expiry. Single-use. Locked to this address — if it wasn't you, ignore.</p>
        """
      )

    deliver(email, "You're invited to Kite Agent Hub", html, text)
  end
end
