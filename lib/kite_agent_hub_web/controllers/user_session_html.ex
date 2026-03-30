defmodule KiteAgentHubWeb.UserSessionHTML do
  use KiteAgentHubWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:kite_agent_hub, KiteAgentHub.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
