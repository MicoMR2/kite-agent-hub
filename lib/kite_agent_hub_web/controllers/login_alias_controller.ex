defmodule KiteAgentHubWeb.LoginAliasController do
  @moduledoc """
  Permanent-redirect controller for the legacy underscore login URLs
  (`/users/log_in`, `/users/log_out`). The canonical paths are
  `/users/log-in` and `/users/log-out` (hyphen) — Phoenix.gen.auth
  switched the URL format and any browser bookmark or external link
  using the old underscore form would have hit a 404 until this PR.

  Mico hit this exact 404 in prod after PR #94 — his browser was
  cached on `/users/log_in` and the redirect from `/dashboard` was
  going there too somehow. Adding the alias so any stale URL gracefully
  forwards to the real route instead of 404'ing.
  """
  use KiteAgentHubWeb, :controller

  def show(conn, _params) do
    redirect(conn, to: ~p"/users/log-in")
  end

  def delete(conn, _params) do
    redirect(conn, to: ~p"/users/log-out")
  end
end
