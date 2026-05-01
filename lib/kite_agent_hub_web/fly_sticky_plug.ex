defmodule KiteAgentHubWeb.FlyStickyPlug do
  @moduledoc """
  Pin Phoenix LiveView longpoll sessions to a specific Fly machine via
  the `fly-replay` response header.

  When the JS client falls back from WebSocket to longpoll, each poll
  is a separate HTTP request. With multiple Fly machines and no session
  affinity, polls bounce between machines: the LV process exists on
  one machine, but a poll landing on another machine sees no such
  session and the client treats it as a disconnect, triggering a
  reconnect storm.

  The fix:
    1. On the first /live/longpoll request that has no affinity cookie,
       set `_kah_fly_machine` to the current `FLY_MACHINE_ID`.
    2. On subsequent requests, if the cookie names a different machine,
       short-circuit with `fly-replay: instance=<id>` so Fly's proxy
       routes the request to the originating machine.

  Phoenix's `:socket_dispatch` plug is the very first plug in the
  endpoint pipeline (added by `use Phoenix.Endpoint`), and it halts
  for socket paths. To run before it we register an extra
  `@before_compile` hook (see `__before_compile__/1`) that overrides
  the endpoint's auto-generated `call/2` to invoke this plug first.
  """

  import Plug.Conn
  require Logger

  @cookie "_kah_fly_machine"
  @max_age 60 * 60 * 24

  def init(opts), do: opts

  def call(%{path_info: ["live", "longpoll" | _]} = conn, _opts) do
    case System.get_env("FLY_MACHINE_ID") do
      id when is_binary(id) and id != "" -> do_sticky(conn, id)
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp do_sticky(conn, current_id) do
    conn = fetch_cookies(conn)
    cookie_id = conn.cookies[@cookie]

    cond do
      is_nil(cookie_id) or cookie_id == "" ->
        put_resp_cookie(conn, @cookie, current_id,
          http_only: true,
          secure: true,
          same_site: "Lax",
          max_age: @max_age,
          path: "/"
        )

      cookie_id == current_id ->
        conn

      true ->
        Logger.info(
          "FlyStickyPlug: replaying longpoll to instance=#{cookie_id} (here=#{current_id})"
        )

        conn
        |> put_resp_header("fly-replay", "instance=#{cookie_id}")
        |> send_resp(204, "")
        |> halt()
    end
  end

  @doc """
  `@before_compile` hook for the endpoint module. Overrides the
  endpoint's `call/2` to run `FlyStickyPlug.call/2` before Phoenix's
  socket dispatch, so longpoll requests for the wrong machine get
  fly-replayed before they reach the longpoll transport.
  """
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        case KiteAgentHubWeb.FlyStickyPlug.call(conn, []) do
          %{halted: true} = halted -> halted
          passing -> super(passing, opts)
        end
      end
    end
  end
end
