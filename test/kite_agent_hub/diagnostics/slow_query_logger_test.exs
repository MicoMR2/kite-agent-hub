defmodule KiteAgentHub.Diagnostics.SlowQueryLoggerTest do
  @moduledoc """
  Locks the PR-C contract that SlowQueryLogger measures *caller-visible*
  latency only — `queue + query + decode` per the module docstring —
  and never trips on `:idle_time` (connection-pool sit time). Pre-PR-C
  the sum included idle_time, producing 20-55s false-positive warnings
  on api_credentials when actual query_time was ~2ms (DevOps msg 10678).
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias KiteAgentHub.Diagnostics.SlowQueryLogger

  # Native time unit on most BEAM hosts is 1ns. Convert ms → native for
  # synthetic telemetry measurements.
  defp ms(n), do: System.convert_time_unit(n, :millisecond, :native)

  test "high idle_time + low caller latency does NOT trip the warning" do
    measurements = %{
      queue_time: ms(1),
      query_time: ms(2),
      decode_time: ms(1),
      # 30s of pool-side idleness — pre-PR-C this tripped the 100ms
      # threshold and surfaced as "SlowQueryLogger: total=30000ms ...".
      idle_time: ms(30_000)
    }

    log = capture_log(fn -> SlowQueryLogger.handle_event([], measurements, %{source: "api_credentials"}, nil) end)

    refute log =~ "SlowQueryLogger:"
  end

  test "high query_time DOES trip the warning (real slow query path)" do
    measurements = %{
      queue_time: ms(0),
      query_time: ms(250),
      decode_time: ms(5),
      idle_time: ms(0)
    }

    log =
      capture_log(fn ->
        SlowQueryLogger.handle_event([], measurements, %{source: "trade_records", query: "SELECT ..."}, nil)
      end)

    assert log =~ "SlowQueryLogger:"
    assert log =~ "source=trade_records"
  end

  test "high queue_time DOES trip the warning (pool contention path)" do
    measurements = %{
      queue_time: ms(500),
      query_time: ms(1),
      decode_time: ms(0),
      idle_time: ms(0)
    }

    log =
      capture_log(fn ->
        SlowQueryLogger.handle_event([], measurements, %{source: "trade_records"}, nil)
      end)

    assert log =~ "SlowQueryLogger:"
  end
end
