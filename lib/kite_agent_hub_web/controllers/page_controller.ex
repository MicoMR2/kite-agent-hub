defmodule KiteAgentHubWeb.PageController do
  use KiteAgentHubWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
