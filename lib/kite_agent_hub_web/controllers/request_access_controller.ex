defmodule KiteAgentHubWeb.RequestAccessController do
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Accounts.{AccessRequest, Invites}

  def new(conn, _params) do
    render(conn, :new, changeset: AccessRequest.request_changeset(%{}))
  end

  def create(conn, %{"access_request" => attrs}) do
    if rate_limited?(conn, attrs["email"]) do
      conn
      |> put_flash(:error, "Too many requests. Try again in an hour.")
      |> render(:new, changeset: AccessRequest.request_changeset(attrs))
    else
      case Invites.request_access(attrs) do
        {:ok, _req} ->
          conn
          |> put_flash(:info, "Got it. We'll review your request and get back to you by email.")
          |> redirect(to: ~p"/request-access/thanks")

        {:error, %Ecto.Changeset{} = changeset} ->
          render(conn, :new, changeset: changeset)
      end
    end
  end

  def thanks(conn, _params) do
    render(conn, :thanks)
  end

  ## Per-IP + per-email throttle: 3 submissions / hour, ETS-backed.
  ## Node-local — acceptable for hackathon traffic.
  @table :kah_request_access_throttle
  @max_per_hour 3
  @window_ms 3_600_000

  defp rate_limited?(conn, email) do
    ensure_table()
    bucket = System.system_time(:millisecond) |> div(@window_ms)
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    norm_email = (email || "") |> String.downcase()

    Enum.any?([{ip, bucket}, {norm_email, bucket}], fn key ->
      count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
      count > @max_per_hour
    end)
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
