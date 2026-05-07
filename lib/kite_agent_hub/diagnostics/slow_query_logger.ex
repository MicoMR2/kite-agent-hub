defmodule KiteAgentHub.Diagnostics.SlowQueryLogger do
  @moduledoc """
  Telemetry handler that logs every Ecto query whose total time
  (queue + query + decode) exceeds `@threshold_ms`. Attached at app
  boot via `attach/0` from `KiteAgentHub.Application.start/2`.

  Why this exists
  ---------------
  Tonight's burst pattern (msg 8268) wasn't slow individual queries
  per the EXPLAIN ANALYZE — it was something holding a Repo
  connection past the 15s pool checkout timeout. Code-level grep
  has hit its ceiling; runtime Telemetry data is the next move.

  When a burst hits, the offending function name + caller stack
  will land in `Logger.warning` lines tagged
  `SlowQueryLogger:` so we can grep prod logs after a burst window
  and name the holder.

  No query parameter values are logged (only the SQL template + the
  `:source` table name from Ecto's metadata). No PII surface.
  """

  require Logger

  @event [:kite_agent_hub, :repo, :query]
  # Thresholds in microseconds — Ecto telemetry measurements are in
  # native time units which `System.convert_time_unit/3` normalizes
  # to microseconds.
  @threshold_microseconds 100_000

  @doc "Attach the handler. Idempotent — safe to call multiple times."
  def attach do
    :telemetry.attach(
      "kah-slow-query-logger",
      @event,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(_event, measurements, metadata, _config) do
    total =
      [:queue_time, :query_time, :decode_time, :idle_time]
      |> Enum.map(fn key ->
        case Map.get(measurements, key) do
          nil -> 0
          n when is_integer(n) -> System.convert_time_unit(n, :native, :microsecond)
          _ -> 0
        end
      end)
      |> Enum.sum()

    if total >= @threshold_microseconds do
      log_slow(total, measurements, metadata)
    end

    :ok
  rescue
    # Never let a telemetry handler crash the calling Ecto query.
    e ->
      Logger.error(
        "SlowQueryLogger: handler crashed (will not stop emitting): #{Exception.message(e)}"
      )

      :ok
  end

  defp log_slow(total_us, measurements, metadata) do
    queue_us =
      Map.get(measurements, :queue_time, 0) |> System.convert_time_unit(:native, :microsecond)

    query_us =
      Map.get(measurements, :query_time, 0) |> System.convert_time_unit(:native, :microsecond)

    decode_us =
      Map.get(measurements, :decode_time, 0) |> System.convert_time_unit(:native, :microsecond)

    source = Map.get(metadata, :source) || "unknown"
    query = Map.get(metadata, :query) || "<unknown>"

    Logger.warning(
      "SlowQueryLogger: " <>
        "total=#{format_ms(total_us)} " <>
        "queue=#{format_ms(queue_us)} " <>
        "query=#{format_ms(query_us)} " <>
        "decode=#{format_ms(decode_us)} " <>
        "source=#{source} " <>
        "sql=#{truncate(query, 200)}"
    )
  end

  defp format_ms(us) when is_integer(us), do: "#{Float.round(us / 1000.0, 2)}ms"
  defp format_ms(_), do: "?ms"

  defp truncate(s, max) when is_binary(s) do
    if byte_size(s) <= max, do: s, else: binary_part(s, 0, max) <> "…"
  end

  defp truncate(_, _), do: "<non-string>"
end
