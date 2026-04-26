defmodule KiteAgentHubWeb.LegalController do
  use KiteAgentHubWeb, :controller

  plug :put_root_layout, html: {KiteAgentHubWeb.Layouts, :legal}
  plug :put_layout, false

  @effective_date "2026-04-26"

  def terms(conn, _params), do: render(conn, :terms, effective_date: @effective_date)
  def privacy(conn, _params), do: render(conn, :privacy, effective_date: @effective_date)
  def disclaimer(conn, _params), do: render(conn, :disclaimer, effective_date: @effective_date)
end
